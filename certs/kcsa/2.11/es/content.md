# Tema 2.11: Storage — Seguridad del almacenamiento en Kubernetes

> Dominio 2 del KCSA — *Kubernetes Cluster Component Security*. Peso 2.0. Este material trata el almacenamiento **como superficie de ataque**: dónde vive el estado del clúster, cómo un volumen mal declarado se convierte en una fuga de datos o en un container escape, y qué controles del propio Kubernetes cierran esos caminos.

---

## 1. Motivación y problema arquitectónico de producción

En un clúster, "storage" no es un servicio periférico: es donde se materializa **todo el estado sensible**. Hay dos planos que un arquitecto de seguridad debe distinguir con precisión, porque sus amenazas y sus controles son distintos:

**Plano de control — etcd.** Todos los objetos de la API (Secrets, ConfigMaps, ServiceAccounts, RBAC, tokens) se persisten en etcd. Un dato incómodo que el KCSA evalúa de forma explícita: **por defecto, los Secrets NO se cifran en etcd; se guardan únicamente codificados en base64.** Cualquiera con acceso de lectura al filesystem del nodo de control (`/var/lib/etcd`), a un backup de etcd, o al snapshot de un disco, obtiene todos los secretos del clúster en claro tras un `base64 -d`. La base64 no es un control de seguridad — es una codificación de transporte.

**Plano de datos — volúmenes de Pod.** Aquí el problema arquitectónico es que **el volumen es la frontera entre el contenedor y el host**. Un `hostPath` bien elegido (`/`, `/var/run/docker.sock`, `/etc/kubernetes/pki`) transforma un contenedor sin privilegios en control total del nodo. Los drivers CSI corren como DaemonSets **privilegiados** con acceso a `/dev`, `/var/lib/kubelet` y a la propagación de montajes del host: comprometer un pod CSI es comprometer el nodo. Y los bugs históricos de `subPath` (CVE-2017-1002101, CVE-2021-25741) demostraron que incluso volúmenes "normales" permitían, mediante symlinks y race conditions, leer y escribir fuera del volumen, en el filesystem del host.

El problema de producción, entonces, es de **defensa en profundidad sobre el estado**:

1. **Confidencialidad en reposo**: cifrar etcd (encryption at rest) y los volúmenes persistentes (cifrado del backend de storage).
2. **Aislamiento del plano de datos**: impedir que un Pod use tipos de volumen que crucen la frontera host/contenedor (Pod Security Standards).
3. **Mínimo privilegio en el montaje**: `readOnly`, `defaultMode` restrictivo, `readOnlyRootFilesystem`, tokens proyectados de vida corta.
4. **Prevención de DoS por almacenamiento**: límites de `ephemeral-storage` y `sizeLimit` en `emptyDir` para que un pod no llene el disco del nodo y desaloje a sus vecinos.

```
                    ┌──────────────────────── Nodo de control ───────────────────────┐
   kubectl create   │   kube-apiserver ──(EncryptionConfiguration)──► etcd            │
   secret           │        │                                   /var/lib/etcd         │
        ────────────┼───────►│   sin cifrar por defecto = base64 en disco             │
                    └────────┼───────────────────────────────────────────────────────┘
                             │
                    ┌────────┼──────────────── Nodo worker ──────────────────────────┐
                    │     kubelet ──► /var/lib/kubelet/pods/<uid>/volumes/...         │
                    │        │            ▲ CSI node plugin (privileged DaemonSet)    │
                    │        │            │ mount propagation ─► host mounts          │
                    │     Pod ── volumeMounts ──► emptyDir | secret | hostPath | PVC  │
                    └────────────────────────────────────────────────────────────────┘
```

---

## 2. Comparativas técnicas con tablas de trade-offs

### 2.1 Tipos de volumen y su riesgo de seguridad

| Tipo | Persistencia | Frontera que cruza | Riesgo principal | PSS `restricted` |
|---|---|---|---|---|
| `emptyDir` | Vida del Pod | Ninguna (dir del nodo) | DoS de disco si no hay `sizeLimit` | ✅ Permitido |
| `configMap` / `secret` | — (proyectado) | Ninguna | Permisos de fichero laxos (`defaultMode 0644`) | ✅ Permitido |
| `projected` (SA token) | — | Ninguna | Token de larga vida si no se usa proyección con expiración | ✅ Permitido |
| `persistentVolumeClaim` | Independiente del Pod | Backend externo | Datos en reposo sin cifrar; reclaim `Retain` deja datos huérfanos | ✅ Permitido |
| `csi` (ephemeral inline) | Vida del Pod | Driver del nodo | Superficie del driver; parámetros no validados | ✅ Permitido |
| `hostPath` | Host | **Filesystem del host** | **Container escape / lectura de secretos del nodo** | ❌ **Prohibido** |
| `nfs` / in-tree cloud | Externo | Red / cloud API | Tráfico en claro; credenciales embebidas | ⚠️ Depende |

**Trade-off clave:** `hostPath` es la única forma de dar a un pod acceso legítimo a rutas del nodo (agentes de logging, node-exporter), pero es también el vector de escape más común. La regla de producción: si un pod necesita `hostPath`, debe montarse `readOnly`, con una subruta lo más específica posible, y ese pod queda fuera del namespace de aplicaciones (namespaces de sistema con PSS `privileged` bien aislados por RBAC).

### 2.2 Providers de encryption-at-rest para etcd

| Provider | Cifrado | Clave | Fortaleza | Uso recomendado |
|---|---|---|---|---|
| `identity` | **Ninguno** | — | **Sin protección (default)** | Nunca en producción |
| `aescbc` | AES-CBC + PKCS#7 | Local (en el manifiesto) | Media; vulnerable a padding si mal implementado | Legado |
| `secretbox` | XSalsa20+Poly1305 | Local | Rápido, AEAD | Aceptable, clave local |
| `aesgcm` | AES-GCM (AEAD) | Local | Fuerte, **pero requiere rotación de clave frecuente** (nonce reuse) | Con rotación disciplinada |
| `kms` v2 | AES-GCM con DEK/KEK envelope | **Externa (KMS)** | Fuerte; clave fuera del clúster | **Producción (GA en v1.29)** |

**Trade-off:** los providers locales guardan la clave en el propio nodo de control (`/etc/kubernetes/enc/`), de modo que quien roba el disco de etcd probablemente también roba la clave. **KMS v2** rompe esa correlación: el clúster solo tiene la KEK en un HSM/KMS remoto y cifra una DEK por objeto (envelope encryption), por lo que un snapshot de etcd es inútil sin acceso al KMS. El costo es una dependencia externa en la ruta de escritura de la API.

### 2.3 Access modes y su implicación de seguridad

| Access mode | Nodos | Pods | Nota de seguridad |
|---|---|---|---|
| `ReadWriteOnce` (RWO) | 1 | varios en el mismo nodo | Un pod hostil colocado en el mismo nodo puede leer el volumen |
| `ReadOnlyMany` (ROX) | varios | varios | Sin escritura; menor superficie |
| `ReadWriteMany` (RWX) | varios | varios | Mayor exposición; requiere backend con control de acceso propio |
| `ReadWriteOncePod` (RWOP) | 1 | **exactamente 1** | **GA en v1.29**; garantiza que ningún otro pod monte el volumen |

**RWOP** es el modo de máximo aislamiento: hasta su llegada, RWO permitía que múltiples pods del mismo nodo compartieran el PV sin que el scheduler lo impidiera.

---

## 3. Manifiestos YAML e infraestructura completos

### 3.1 EncryptionConfiguration con KMS v2 (y fallback local)

Fichero `/etc/kubernetes/enc/encryption-config.yaml` en cada nodo de control, referenciado por `--encryption-provider-config` en el kube-apiserver:

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
      - configmaps                 # incluir CM si guardan datos sensibles
    providers:
      # El primer provider escribe; todos se prueban al leer (rotación segura).
      - kms:
          apiVersion: v2
          name: cluster-kms
          endpoint: unix:///var/run/kmsplugin/socket.sock
          timeout: 3s
      # Fallback local por si el KMS no responde durante la migración.
      - aesgcm:
          keys:
            - name: key-2026-08
              secret: c2VjcmV0LWRlLTMyLWJ5dGVzLXJvdGFyLW1lbnN1YWw=
      # 'identity' al final = capacidad de leer objetos aún sin cifrar.
      - identity: {}
```

Flag correspondiente en el manifiesto estático del apiserver (`/etc/kubernetes/manifests/kube-apiserver.yaml`):

```yaml
    - --encryption-provider-config=/etc/kubernetes/enc/encryption-config.yaml
    - --encryption-provider-config-automatic-reload=true
```

### 3.2 Pod endurecido: volúmenes de mínimo privilegio

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: hardened-app
  namespace: payments
spec:
  automountServiceAccountToken: false     # no montar el token si no se usa la API
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    fsGroup: 20000                         # grupo dueño de los volúmenes escribibles
    fsGroupChangePolicy: OnRootMismatch    # evita chown recursivo innecesario (perf + menos escritura)
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: registry.example.com/app@sha256:0f1e...c9
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true       # raíz inmutable: el atacante no persiste binarios
        capabilities:
          drop: ["ALL"]
      volumeMounts:
        - name: cache
          mountPath: /var/cache/app        # única ruta escribible
        - name: db-credentials
          mountPath: /etc/secrets
          readOnly: true                    # el secreto se monta sólo lectura
        - name: sa-token
          mountPath: /var/run/secrets/tokens
          readOnly: true
  volumes:
    - name: cache
      emptyDir:
        sizeLimit: 256Mi                    # tope anti-DoS de disco del nodo
    - name: db-credentials
      secret:
        secretName: db-credentials
        defaultMode: 0400                   # sólo el owner lee; NO el default 0644
    - name: sa-token
      projected:                            # token acotado, de vida corta
        sources:
          - serviceAccountToken:
              path: token
              audience: vault
              expirationSeconds: 3600
```

### 3.3 StorageClass con cifrado en reposo del backend

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: encrypted-ssd
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"                         # cifrado a nivel de volumen (CMK del cloud)
  kmsKeyId: arn:aws:kms:eu-west-1:111122223333:key/abcd-...
reclaimPolicy: Delete                        # 'Retain' deja discos con datos si no hay limpieza
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
```

### 3.4 PVC que exige aislamiento estricto de pod

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ledger-data
  namespace: payments
spec:
  accessModes: ["ReadWriteOncePod"]          # GA v1.29: un solo pod puede montarlo
  storageClassName: encrypted-ssd
  resources:
    requests:
      storage: 20Gi
```

---

## 4. Comandos CLI y salidas de terminal reales

### 4.1 Demostrar que un Secret NO está cifrado en etcd

```console
$ kubectl -n payments create secret generic db-credentials \
    --from-literal=password='S3rv1c3-Pa55!'
secret/db-credentials created

$ ETCDCTL_API=3 etcdctl \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    get /registry/secrets/payments/db-credentials | hexdump -C | head
00000000  2f 72 65 67 69 73 74 72  79 2f 73 65 63 72 65 74  |/registry/secret|
00000010  73 2f 70 61 79 6d 65 6e  74 73 2f 64 62 2d 63 72  |s/payments/db-cr|
00000020  ...
000000a0  53 33 72 76 31 63 33 2d  50 61 35 35 21 0a 6b 38  |S3rv1c3-Pa55!.k8|
```

La contraseña aparece **en claro** dentro de etcd. Tras habilitar la `EncryptionConfiguration` con KMS/aesgcm, el mismo `get` muestra un prefijo `k8s:enc:kms:v2:` o `k8s:enc:aesgcm:v1:` seguido de bytes opacos.

### 4.2 Migrar los secretos ya escritos (cifrar en el sitio)

```console
$ kubectl get secrets --all-namespaces -o json \
    | kubectl replace -f -
secret/db-credentials replaced
secret/default-token-x9f2k replaced
...
```

> La `EncryptionConfiguration` sólo cifra objetos **al escribir**. Los secretos preexistentes siguen en claro hasta que se los reescribe; este `get | replace` fuerza esa reescritura.

### 4.3 Auditar tipos de volumen peligrosos en el clúster

```console
$ kubectl get pods -A -o json | jq -r '
  .items[]
  | select(.spec.volumes != null)
  | . as $p
  | .spec.volumes[]
  | select(.hostPath != null)
  | "\($p.metadata.namespace)/\($p.metadata.name)  ->  \(.hostPath.path)"'
kube-system/node-exporter-7bd2c  ->  /
monitoring/fluentd-9xk4z         ->  /var/log
default/debug-shell              ->  /var/run/docker.sock
```

`default/debug-shell` montando el socket de Docker es un escape trivial a root del nodo — hallazgo crítico.

### 4.4 Verificar los permisos reales del secret dentro del contenedor

```console
$ kubectl -n payments exec hardened-app -- ls -l /etc/secrets
total 0
lrwxrwxrwx 1 root root 15 Aug  7 12:04 password -> ..data/password

$ kubectl -n payments exec hardened-app -- stat -c '%a %U:%G' /etc/secrets/..data/password
400 root:root
```

Con `defaultMode: 0644` (el default) el último comando devolvería `644`, legible por cualquier proceso del contenedor. `0400` lo restringe.

### 4.5 Confirmar la raíz inmutable

```console
$ kubectl -n payments exec hardened-app -- touch /tmp/x
touch: cannot touch '/tmp/x': Read-only file system
command terminated with exit code 1

$ kubectl -n payments exec hardened-app -- touch /var/cache/app/x
$   # OK: única ruta escribible, respaldada por emptyDir con sizeLimit
```

---

## 5. Guía de verificación y diagnóstico de fallas

### 5.1 ¿Está realmente activo el encryption-at-rest?

```console
$ ps aux | grep kube-apiserver | grep -o 'encryption-provider-config[^ ]*'
--encryption-provider-config=/etc/kubernetes/enc/encryption-config.yaml
```

Si el flag no aparece, **no hay cifrado, sin importar lo que diga la política escrita**. Confirmá luego con el `etcdctl get` de §4.1: el prefijo `k8s:enc:` es la única prueba real.

### 5.2 Fallo: KMS caído y la API deja de escribir Secrets

Síntoma: `kubectl create secret` cuelga o devuelve `500 Internal Server Error`; en los logs del apiserver:

```
E0807 rpc error: code = DeadlineExceeded desc = context deadline exceeded, kms-provider "cluster-kms" unhealthy
```

Diagnóstico y mitigación:
- Verificar el healthz dedicado del provider KMS:
  ```console
  $ kubectl get --raw '/healthz/kms-provider-0'
  ok
  ```
- Si devuelve `internal server error`, el plugin KMS no responde en su socket. Con `--encryption-provider-config-automatic-reload=true` se puede recargar la config sin reiniciar el apiserver. El provider `identity` como fallback permite **leer** objetos aún no cifrados, pero **no** sustituye al KMS para escritura si el KMS es el primer provider.

### 5.3 Fallo: Pod `Pending` por permisos de volumen / fsGroup lento

Síntoma: pods con PVs grandes tardan minutos en `Running`; el kubelet hace `chown` recursivo del volumen al arrancar.

```console
$ kubectl describe pod big-data-0 | grep -A2 Events
  Warning  FailedMount  2m  kubelet  MountVolume.SetUp ... applying fsGroup ownership: operation timed out
```

Causa: `fsGroupChangePolicy: Always` (default) recorre y hace `chown` de **cada** fichero. Mitigación: `fsGroupChangePolicy: OnRootMismatch` — solo cambia permisos si el directorio raíz del volumen no coincide con el `fsGroup` esperado.

### 5.4 Fallo/ataque: escape vía `subPath` (contexto histórico, verificación)

CVE-2021-25741 permitía que un `subPath` con symlink accediera a rutas del host durante una race condition del montaje. Verificación de mitigación:

```console
$ kubectl version -o json | jq -r '.serverVersion.gitVersion'
v1.29.4
```

Kubernetes ≥ 1.22 incorpora la corrección. Como control compensatorio, evitar `subPath` sobre volúmenes escribibles por el contenedor y preferir `subPathExpr` sólo con valores controlados por el operador.

### 5.5 Fallo: DoS de disco del nodo por `emptyDir` sin límite

Síntoma: nodos pasan a `DiskPressure`, pods desalojados en cascada.

```console
$ kubectl get nodes -o custom-columns='NODE:.metadata.name,DISKPRESSURE:.status.conditions[?(@.type=="DiskPressure")].status'
NODE        DISKPRESSURE
worker-3    True

$ kubectl describe node worker-3 | grep -A3 'Evicted'
  Warning  Evicted  ...  The node was low on resource: ephemeral-storage. Container app was using 9Gi, exceeds the limit
```

Mitigación: `emptyDir.sizeLimit`, `resources.limits.ephemeral-storage` por contenedor, y ResourceQuota de `requests.ephemeral-storage` por namespace.

### 5.6 Checklist de auditoría de storage (rápida)

```console
# 1. Secrets sin cifrar en etcd
$ kubectl get --raw '/healthz/etcd' && etcdctl get /registry/secrets/... | grep -c 'k8s:enc:'

# 2. hostPath en namespaces de aplicación
$ kubectl get pods -A -o json | jq '[.items[].spec.volumes[]?|select(.hostPath)]|length'

# 3. Secrets con defaultMode permisivo
$ kubectl get pods -A -o json | jq -r '.items[].spec.volumes[]?|select(.secret.defaultMode>256)'

# 4. PVs con reclaimPolicy Retain (datos huérfanos)
$ kubectl get pv -o custom-columns='PV:.metadata.name,POLICY:.spec.persistentVolumeReclaimPolicy,STATUS:.status.phase'

# 5. Pods sin readOnlyRootFilesystem
$ kubectl get pods -A -o json | jq -r '.items[]|select(any(.spec.containers[];.securityContext.readOnlyRootFilesystem!=true))|.metadata.name'
```

---

## 6. Referencias

- Encryption at rest / EncryptionConfiguration — https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
- KMS v2 provider (GA en v1.29) — https://kubernetes.io/docs/tasks/administer-cluster/kms-provider/
- Secrets — riesgos y buenas prácticas — https://kubernetes.io/docs/concepts/configuration/secret/#security-properties
- Tipos de volumen — https://kubernetes.io/docs/concepts/storage/volumes/
- Persistent Volumes, access modes y reclaim policies — https://kubernetes.io/docs/concepts/storage/persistent-volumes/
- Storage Classes — https://kubernetes.io/docs/concepts/storage/storage-classes/
- Configurar SecurityContext (`fsGroup`, `fsGroupChangePolicy`, `readOnlyRootFilesystem`) — https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- Projected volumes / bound service account tokens — https://kubernetes.io/docs/concepts/storage/projected-volumes/
- Pod Security Standards (restricción de `hostPath`) — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Container Storage Interface (CSI) — https://kubernetes-csi.github.io/docs/
- Ephemeral storage y eviction por `DiskPressure` — https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/
- CVE-2021-25741 (subPath symlink) — https://github.com/kubernetes/kubernetes/issues/104980
- CVE-2017-1002101 (subPath volume mount) — https://github.com/kubernetes/kubernetes/issues/60813
- KCSA Curriculum (CNCF) — https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf