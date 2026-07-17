# 6.5 Use Kubernetes audit logs to monitor access

## ¿Qué es el audit log en Kubernetes?

El **audit log** de Kubernetes es un registro estructurado (JSON) de cada request que llega al `kube-apiserver`: quién lo hizo (user/service account), qué verbo usó (`get`, `list`, `create`, `delete`, `patch`, `exec`, `impersonate`...), sobre qué recurso, con qué resultado y en qué momento. Es la herramienta principal para **forensics** y detección de accesos indebidos, porque el apiserver es el único punto de entrada al plano de control: todo pasa por ahí (kubectl, controllers, kubelet, otros componentes).

La auditoría es responsabilidad exclusiva del `kube-apiserver` — no existe auditoría nativa en scheduler, controller-manager ni kubelet. Se activa con flags al arrancar el apiserver; en clusters `kubeadm` esto significa editar el static pod manifest en `/etc/kubernetes/manifests/kube-apiserver.yaml`.

### Fases (stages) de una request auditada

Cada request puede generar hasta 4 eventos, uno por *stage*:

- `RequestReceived`: apenas llega la request (antes de procesarla).
- `ResponseStarted`: se envió el header de la respuesta (usado en long-running requests como `watch`).
- `ResponseComplete`: terminó de enviarse el body.
- `Panic`: ocurrió un error interno.

### Niveles de auditoría (audit level)

La **audit policy** define, por regla, cuánto detalle se registra:

| Nivel | Qué guarda |
|---|---|
| `None` | No loguea nada para las requests que matchean la regla. |
| `Metadata` | User, timestamp, resource, verb — sin body de request ni response. |
| `Request` | Metadata + body de la request (no el de la response). |
| `RequestResponse` | Metadata + body de request y de response completos. |

`RequestResponse` es el más costoso en tamaño de log y en I/O — usarlo indiscriminadamente en un cluster grande puede degradar el apiserver. La práctica recomendada (y típica en el examen) es un nivel base bajo (`Metadata` o `None`) y subir a `Request`/`RequestResponse` solo para recursos sensibles (`secrets`, `configmaps`, RBAC, `pods/exec`).

## Audit policy: estructura

La policy es un objeto `Policy` (`apiVersion: audit.k8s.io/v1`) con una lista de `rules`. **Las reglas se evalúan en orden y se aplica la primera que matchea** — por eso las reglas más específicas van primero y una catch-all va al final.

```yaml
# /etc/kubernetes/audit-policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
  - "RequestReceived"          # no logueamos la fase inicial, solo la completa
rules:
  # No auditar lecturas de health/discovery: mucho ruido, cero valor
  - level: None
    nonResourceURLs:
      - "/healthz*"
      - "/livez*"
      - "/readyz*"
      - "/api*"
      - "/version"

  # Secrets y ConfigMaps: nivel Metadata (no queremos el valor de los secrets en texto plano en el log)
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]

  # Auditoría completa de exec/attach/portforward a pods: vector clásico de abuso
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["pods/exec", "pods/attach", "pods/portforward"]

  # Cualquier acción de un usuario o SA por fuera del namespace kube-system sobre RBAC
  - level: RequestResponse
    verbs: ["create", "update", "patch", "delete"]
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]

  # Todo lo demás, a nivel Metadata
  - level: Metadata
```

Campos de filtrado disponibles en cada regla: `level`, `resources` (con `group`/`resources`/opcionalmente `resourceNames`), `namespaces`, `verbs`, `users`, `userGroups`, `nonResourceURLs`, `omitStages`.

## Configurar el kube-apiserver para auditar

1. Guardar la policy en el filesystem del control-plane node (ej. `/etc/kubernetes/audit-policy.yaml`).
2. Editar el static pod manifest del apiserver agregando flags + volumeMounts:

```yaml
# /etc/kubernetes/manifests/kube-apiserver.yaml (fragmento)
spec:
  containers:
  - command:
    - kube-apiserver
    - --audit-policy-file=/etc/kubernetes/audit-policy.yaml
    - --audit-log-path=/var/log/kubernetes/audit/audit.log
    - --audit-log-maxage=7          # días
    - --audit-log-maxbackup=10      # cantidad de archivos rotados
    - --audit-log-maxsize=100       # MB por archivo
    - --audit-log-format=json
    volumeMounts:
    - mountPath: /etc/kubernetes/audit-policy.yaml
      name: audit-policy
      readOnly: true
    - mountPath: /var/log/kubernetes/audit/
      name: audit-log
  volumes:
  - name: audit-policy
    hostPath:
      path: /etc/kubernetes/audit-policy.yaml
      type: File
  - name: audit-log
    hostPath:
      path: /var/log/kubernetes/audit/
      type: DirectoryOrCreate
```

Al ser un static pod, `kubelet` detecta el cambio en el manifest y **reinicia el apiserver automáticamente** — no hace falta `kubectl apply`. Conviene verificar que vuelva a levantar:

```bash
crictl ps | grep kube-apiserver
# o, si el pod ya está gestionado por la API:
kubectl -n kube-system get pod -l component=kube-apiserver
```

Si el apiserver no vuelve (manifest mal formado o volumen inexistente), revisar los logs del kubelet (`journalctl -u kubelet`) o los del contenedor con `crictl logs <id>`.

## Backend webhook (alternativa/complemento al log a disco)

Además del *log backend* (archivo local), Kubernetes soporta un *webhook backend* que envía cada evento a un endpoint HTTP externo — útil para centralizar en un SIEM:

```bash
--audit-webhook-config-file=/etc/kubernetes/audit-webhook-kubeconfig
--audit-webhook-batch-max-wait=5s
```

El archivo referenciado tiene formato `kubeconfig` estándar y apunta al `server:` que recibirá los eventos.

## Leer e interpretar el audit log

```bash
tail -f /var/log/kubernetes/audit/audit.log | jq .
```

Un evento típico (nivel `Metadata`, un `get` sobre un Secret):

```json
{
  "kind": "Event",
  "apiVersion": "audit.k8s.io/v1",
  "level": "Metadata",
  "auditID": "3b2f9e0a-1234-4c8a-9a2b-8f6e1d2c3a4b",
  "stage": "ResponseComplete",
  "requestURI": "/api/v1/namespaces/prod/secrets/db-creds",
  "verb": "get",
  "user": {
    "username": "system:serviceaccount:prod:payments-sa",
    "groups": ["system:serviceaccounts", "system:serviceaccounts:prod", "system:authenticated"]
  },
  "sourceIPs": ["10.244.1.7"],
  "objectRef": {
    "resource": "secrets",
    "namespace": "prod",
    "name": "db-creds",
    "apiVersion": "v1"
  },
  "responseStatus": {
    "metadata": {},
    "code": 200
  },
  "requestReceivedTimestamp": "2026-07-17T14:02:11.203421Z",
  "stageTimestamp": "2026-07-17T14:02:11.211903Z"
}
```

### Queries típicas de investigación (ejercicio clásico de examen)

```bash
# Todos los "delete" hechos por un usuario específico
jq 'select(.verb=="delete" and .user.username=="jdoe")' \
  /var/log/kubernetes/audit/audit.log

# Todo acceso (cualquier verbo) a un Secret puntual
jq 'select(.objectRef.resource=="secrets" and .objectRef.name=="db-creds")' \
  /var/log/kubernetes/audit/audit.log

# Detectar impersonation (un usuario actuando "como" otro)
jq 'select(.verb=="impersonate")' /var/log/kubernetes/audit/audit.log

# Requests que fallaron por autorización (403)
jq 'select(.responseStatus.code==403)' /var/log/kubernetes/audit/audit.log

# Quién ejecutó "kubectl exec" en el namespace kube-system
jq 'select(.objectRef.resource=="pods" and .objectRef.subresource=="exec"
      and .objectRef.namespace=="kube-system")' \
  /var/log/kubernetes/audit/audit.log
```

## Puntos clave para el examen

- La auditoría es **flag-based en el kube-apiserver**, no un recurso de la API (no hay `kubectl get auditpolicy`).
- **Sin `--audit-policy-file`, no se audita nada** — es el flag mínimo indispensable.
- Orden de reglas importa: **primera regla que matchea gana**; una policy sin regla catch-all al final puede dejar requests sin auditar silenciosamente.
- `RequestResponse` en todo el cluster es un antipatrón de performance — el escenario típico de examen pide auditar en detalle solo un recurso/namespace/verbo puntual y dejar el resto en `Metadata` o `None`.
- Tras editar el manifest, **confirmar que el apiserver volvió a estar `Ready`** antes de dar la tarea por terminada — un typo en la policy YAML puede dejar el apiserver crasheando.
- El archivo de audit log y la audit-policy deben protegerse con permisos de filesystem restrictivos (pertenecen a la superficie de ataque de "quién puede leer los logs sabe qué se está mirando").
- Distinguir el **audit log** (qué pasó vía API) del **log del propio apiserver/contenedores** (stdout/stderr del proceso) — son cosas distintas y el examen puede pedir específicamente uno u otro.

## Referencias

- Auditing — Kubernetes docs: https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- kube-apiserver reference (flags `--audit-*`): https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
- Audit policy API (`audit.k8s.io/v1`): https://kubernetes.io/docs/reference/config-api/apiserver-audit.v1/
- CKS Curriculum v1.34 (CNCF): https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf