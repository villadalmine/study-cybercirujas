# 2.2 Gestionar Secrets de Kubernetes

**Peso del dominio: 5**

## Por qué este tema importa para el CKS

Un `Secret` de Kubernetes *no* es una bóveda segura. Por defecto es un objeto de la API con ámbito de namespace que contiene datos **codificados en base64** (no cifrados), almacenados en texto plano dentro de etcd. El examen CKS espera que sepas exactamente dónde están los límites de confianza y cómo ajustarlos: cifrado en reposo, delimitación con RBAC, consumo seguro dentro de Pods, tokens de ServiceAccount de vida corta y delegación a almacenes de secretos externos.

Las tareas de esta área son casi siempre prácticas: editar el manifiesto del Pod estático `kube-apiserver`, escribir una `EncryptionConfiguration`, demostrar que un Secret está cifrado en etcd, o corregir un Role con permisos excesivos.

---

## 1. Qué es realmente un Secret

```bash
kubectl create secret generic db-creds \
  --from-literal=username=app \
  --from-literal=password='S3cr3t!'
```

```
secret/db-creds created
```

```bash
kubectl get secret db-creds -o yaml
```

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-creds
  namespace: default
type: Opaque
data:
  password: UzNjcjN0IQ==
  username: YXBw
```

Decodificarlo es trivial para cualquiera con acceso de lectura — esto es codificación, no protección:

```bash
kubectl get secret db-creds -o jsonpath='{.data.password}' | base64 -d
```

```
S3cr3t!
```

Propiedades clave que hay que interiorizar:

| Propiedad | Detalle |
|---|---|
| Ámbito | Con namespace. Un Secret sólo puede ser montado por Pods del mismo namespace. |
| Límite de tamaño | 1 MiB por Secret (restricción de etcd/apiserver). Los blobs grandes van en otro lado. |
| Almacenamiento | etcd, **en texto plano por defecto** — cualquiera con acceso al disco de etcd, a un backup o a un snapshot lee todo. |
| `kubectl describe` | Muestra sólo los nombres de las claves y el conteo de bytes, nunca los valores. Útil para demos, no es un control de seguridad. |
| `data` vs `stringData` | `data` requiere base64; `stringData` acepta texto plano y se codifica al escribir (campo de sólo escritura, la API nunca lo devuelve). |

### Tipos de Secret

El campo `type` determina la validación de las claves requeridas:

| Tipo | Claves requeridas | Uso típico |
|---|---|---|
| `Opaque` | ninguna | Clave/valor arbitrario (por defecto) |
| `kubernetes.io/tls` | `tls.crt`, `tls.key` | Certificados de servicio para Ingress / webhooks |
| `kubernetes.io/dockerconfigjson` | `.dockerconfigjson` | `imagePullSecrets` |
| `kubernetes.io/basic-auth` | `username`, `password` | Credenciales de autenticación básica |
| `kubernetes.io/ssh-auth` | `ssh-privatekey` | Git sobre SSH, sidecars |
| `kubernetes.io/service-account-token` | `token` (poblado por el controlador) | Tokens de SA de larga duración, **legacy** |
| `bootstrap.kubernetes.io/token` | `token-id`, `token-secret` | Bootstrap de `kubeadm join` |

---

## 2. Crear Secrets

### Imperativo (el camino más rápido en el examen)

```bash
# From literals
kubectl create secret generic api-key --from-literal=key=abc123

# From files — the file name becomes the key
kubectl create secret generic ssh-key --from-file=ssh-privatekey=/root/.ssh/id_ed25519

# Rename the key explicitly
kubectl create secret generic ca --from-file=ca.crt=/etc/kubernetes/pki/ca.crt

# From a dotenv file (KEY=VALUE per line)
kubectl create secret generic app-env --from-env-file=./app.env

# TLS
kubectl create secret tls web-tls --cert=tls.crt --key=tls.key

# Registry credentials
kubectl create secret docker-registry regcred \
  --docker-server=registry.example.com \
  --docker-username=ci \
  --docker-password='pull-token'
```

Generar YAML sin tocar el clúster — el idiom que hay que recordar:

```bash
kubectl create secret generic db-creds \
  --from-literal=password='S3cr3t!' \
  --dry-run=client -o yaml > db-creds.yaml
```

### Declarativo con `stringData`

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-creds
type: Opaque
stringData:
  username: app
  password: "S3cr3t!"
  config.ini: |
    [db]
    host=postgres.prod.svc
```

### Secrets inmutables

Marcar un Secret como inmutable evita actualizaciones accidentales o maliciosas y permite que el kubelet deje de observarlo (menos carga sobre el apiserver):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-creds
immutable: true
data:
  password: UzNjcjN0IQ==
```

```bash
kubectl patch secret db-creds -p '{"stringData":{"password":"new"}}'
```

```
Error from server: Secret "db-creds" is invalid: data: Forbidden: field is immutable when `immutable` is set
```

Para cambiar el valor hay que borrarlo y recrearlo — lo cual es una acción deliberada y auditable. Tené en cuenta que los Pods que consumen un Secret inmutable por volumen **no** verán actualizaciones.

---

## 3. Consumir Secrets en Pods de forma segura

### Variables de entorno (cómodo, más débil)

```yaml
    env:
      - name: DB_PASSWORD
        valueFrom:
          secretKeyRef:
            name: db-creds
            key: password
            optional: false
    envFrom:
      - secretRef:
          name: app-env
```

Por qué las variables de entorno son la opción más débil:

- Se pueden leer vía `/proc/<pid>/environ` desde cualquier cosa en el mismo namespace de PID, y suelen ser volcadas por manejadores de crash, agentes APM y herramientas del estilo `docker inspect`.
- Con frecuencia las imprimen los logs de arranque de la aplicación o los reportadores de errores.
- **Nunca se actualizan** cuando el Secret cambia — hay que recrear el Pod.
- Los procesos hijos las heredan por defecto.

### Montajes de volumen (preferido)

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app
spec:
  containers:
    - name: app
      image: nginx:1.27-alpine
      volumeMounts:
        - name: creds
          mountPath: /etc/app/creds
          readOnly: true
  volumes:
    - name: creds
      secret:
        secretName: db-creds
        defaultMode: 0400
        items:
          - key: password
            path: db_password
```

```bash
kubectl exec app -- ls -l /etc/app/creds
```

```
total 0
lrwxrwxrwx 1 root root 18 Jul 29 10:14 db_password -> ..data/db_password
```

Puntos para recordar:

- Los volúmenes de Secret están respaldados por `tmpfs` (RAM) — nunca llegan al disco del nodo.
- `items` proyecta sólo las claves que necesitás — mínimo privilegio dentro del contenedor.
- `defaultMode: 0400` restringe los permisos del archivo; combinalo con `runAsUser` para que el UID correcto sea el dueño del archivo.
- Los Secrets montados como volumen son **actualizados en el lugar** por el kubelet tras un cambio (consistencia eventual, aproximadamente el período de sincronización del kubelet más el TTL de la caché). El intercambio del symlink `..data` hace que las actualizaciones sean atómicas.
- **Los montajes con `subPath` no reciben actualizaciones.** Este es un tropiezo clásico.

### `imagePullSecrets`

```bash
kubectl patch serviceaccount default \
  -p '{"imagePullSecrets":[{"name":"regcred"}]}'
```

O por Pod:

```yaml
spec:
  imagePullSecrets:
    - name: regcred
```

### Volúmenes proyectados

Combinar un Secret, un ConfigMap y un token de SA de vida corta en un solo directorio:

```yaml
  volumes:
    - name: bundle
      projected:
        defaultMode: 0400
        sources:
          - secret:
              name: db-creds
              items:
                - key: password
                  path: db/password
          - configMap:
              name: app-config
          - serviceAccountToken:
              path: token
              audience: vault
              expirationSeconds: 3600
```

---

## 4. Quién puede leer tus Secrets

### RBAC: nunca otorgues acceso indiscriminado a Secrets

```yaml
# BAD — reads every Secret in the namespace
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list", "watch"]
```

```yaml
# BETTER — a single named Secret, get only
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: prod
  name: db-creds-reader
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["db-creds"]
    verbs: ["get"]
```

Sutileza crítica: **`resourceNames` no restringe `list` ni `watch`.** Esos verbos operan sobre una colección, no sobre un objeto con nombre, así que otorgar `list` sobre `secrets` con `resourceNames` definido o bien no logra restringir nada significativo o bien es directamente inefectivo. Si un sujeto tiene `list` sobre secrets, puede leer todos los Secrets de su ámbito — incluidos los valores, porque `list` devuelve los objetos completos.

Verificar los permisos efectivos:

```bash
kubectl auth can-i list secrets -n prod --as=system:serviceaccount:prod:app
```

```
no
```

```bash
kubectl auth can-i get secret/db-creds -n prod --as=system:serviceaccount:prod:app
```

```
yes
```

### La vía de escalada por creación de Pods

Cualquiera que pueda **crear un Pod** en un namespace puede montar cualquier Secret de ese namespace y exfiltrarlo — sin necesidad del permiso `get secrets`. Tratá `create pods` (y todo controlador que cree Pods: Deployments, Jobs, CronJobs, StatefulSets, DaemonSets) como equivalente a acceso de lectura sobre todos los Secrets de ese namespace.

Consecuencias para el diseño:
- Usá los namespaces como el verdadero límite de los secretos; no coloques juntas cargas de trabajo no relacionadas.
- Restringí quién puede crear cargas de trabajo en namespaces que contienen Secrets sensibles.
- Las restricciones `escalate`/`bind` no ayudan acá — esto no es una escalada de RBAC, es comportamiento previsto.

### Delimitación a nivel de nodo

```bash
grep -E 'authorization-mode|enable-admission-plugins' /etc/kubernetes/manifests/kube-apiserver.yaml
```

```
    - --authorization-mode=Node,RBAC
    - --enable-admission-plugins=NodeRestriction
```

- El **autorizador Node** limita a cada kubelet a leer únicamente los Secrets referenciados por Pods realmente planificados en su nodo.
- El plugin de admisión **`NodeRestriction`** impide que un kubelet edite su propio objeto Node o los Pods de otros nodos, cerrando la vía por la cual un kubelet comprometido se etiqueta a sí mismo para atraer cargas de trabajo sensibles.

Ambos deben estar presentes. Sin el autorizador Node, las credenciales de un único nodo comprometido pueden leer todos los Secrets del clúster.

### Deshabilitar el montaje innecesario de tokens

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: app
automountServiceAccountToken: false
```

O por Pod (`spec.automountServiceAccountToken: false`), que prevalece sobre la configuración del ServiceAccount. Si una carga de trabajo nunca habla con el servidor de la API, no debería llevar una credencial de la API.

---

## 5. Tokens de ServiceAccount

Los clústeres modernos usan tokens **acotados, de vida corta y delimitados por audiencia** en lugar de los viejos tokens basados en Secrets que no expiraban.

- Desde la v1.24, crear un ServiceAccount ya no crea automáticamente un Secret de token.
- Los Pods reciben un token a través de un **volumen proyectado `serviceAccountToken`**, inyectado automáticamente, que el kubelet rota antes de que expire (por defecto ~1 hora, refrescado al ~80% de su vida útil).
- El token está acotado al Pod y al ServiceAccount: cuando el Pod se elimina, el token deja de ser válido.

Solicitar un token ad-hoc:

```bash
kubectl create token app --duration=10m
```

```
eyJhbGciOiJSUzI1NiIsImtpZCI6Ii4uLiJ9.eyJhdWQ...
```

Inspeccionar el token inyectado dentro de un Pod:

```bash
kubectl exec app -- ls /var/run/secrets/kubernetes.io/serviceaccount
```

```
ca.crt
namespace
token
```

Crear un token legacy de larga duración sigue siendo posible, pero debería tratarse como un hallazgo:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: app-legacy-token
  annotations:
    kubernetes.io/service-account.name: app
type: kubernetes.io/service-account-token
```

Estos tokens nunca expiran y sobreviven a la reutilización del ServiceAccount. Las versiones recientes de Kubernetes registran su último uso (mediante una anotación `kubernetes.io/legacy-token-last-used`) y pueden limpiar los que no se usan, pero la respuesta correcta en una revisión de hardening es eliminarlos y migrar a quienes los llaman a la API TokenRequest.

Ejemplo de token delimitado por audiencia para un consumidor externo (la vinculación de audiencia impide la reutilización del token contra el servidor de la API):

```yaml
          - serviceAccountToken:
              path: vault-token
              audience: https://vault.example.com
              expirationSeconds: 600
```

`expirationSeconds` tiene un piso de 600.

---

## 6. Cifrado en reposo

Esta es la habilidad práctica de mayor valor en este tema. Objetivo: que `kube-apiserver` cifre los Secrets antes de escribirlos en etcd.

### Paso 1 — generar una clave

```bash
head -c 32 /dev/urandom | base64
```

```
7ZQ2rH0mQ5nJv9pC1xK3aLdF8sYtB6uWeR4iO0gN2sM=
```

### Paso 2 — escribir la EncryptionConfiguration

```bash
mkdir -p /etc/kubernetes/enc
cat > /etc/kubernetes/enc/enc.yaml <<'EOF'
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
      - configmaps
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: 7ZQ2rH0mQ5nJv9pC1xK3aLdF8sYtB6uWeR4iO0gN2sM=
      - identity: {}
EOF
chmod 600 /etc/kubernetes/enc/enc.yaml
```

Reglas que determinan el comportamiento:

- **El orden importa.** La primera clave del primer proveedor cifra las escrituras nuevas. Todos los proveedores/claves listados se prueban para descifrar.
- Mantener `identity` **al final** permite leer los datos en texto plano existentes. Poner `identity` **primero** deshabilita el cifrado para las escrituras nuevas — así es como se descifra un clúster.
- `resources` acepta comodines como `*.` (todos los recursos del grupo core) o `*.*` (todo).

### Comparación de proveedores

| Proveedor | Algoritmo | Notas |
|---|---|---|
| `identity` | ninguno | Texto plano. Por defecto cuando no se suministra configuración. |
| `secretbox` | XSalsa20 + Poly1305 | Autenticado, rápido, robusto. |
| `aesgcm` | AES-GCM, nonce aleatorio | Autenticado, rápido — **pero la clave debe rotarse aproximadamente cada 200.000 escrituras**; la reutilización de nonce es catastrófica. |
| `aescbc` | AES-CBC + PKCS#7 | Muy usado en material de examen/laboratorio; no es cifrado autenticado, por lo que la documentación ya no lo recomienda para clústeres nuevos. |
| `kms` (v2) | cifrado por sobre mediante plugin KMS externo | **Recomendado para producción.** La clave que envuelve la DEK nunca toca el host del servidor de la API. |

KMS v1 está obsoleto; los clústeres nuevos deberían usar KMS v2. Los proveedores de clave local guardan la clave en el sistema de archivos del plano de control, así que un atacante con acceso root al plano de control igual gana — que es precisamente la brecha que cierra KMS.

### Paso 3 — conectarlo al servidor de la API

Editá `/etc/kubernetes/manifests/kube-apiserver.yaml`:

```yaml
spec:
  containers:
    - name: kube-apiserver
      command:
        - kube-apiserver
        - --encryption-provider-config=/etc/kubernetes/enc/enc.yaml
        - --encryption-provider-config-automatic-reload=true
        # ... existing flags
      volumeMounts:
        - name: enc
          mountPath: /etc/kubernetes/enc
          readOnly: true
  volumes:
    - name: enc
      hostPath:
        path: /etc/kubernetes/enc
        type: DirectoryOrCreate
```

Guardar el manifiesto hace que el kubelet reinicie el Pod estático. Observá cómo vuelve:

```bash
crictl ps | grep kube-apiserver
```

```
9f3c1a2b8d4e   3   Running   kube-apiserver   0   k8s_kube-apiserver_kube-apiserver-cp_kube-system_...
```

`--encryption-provider-config-automatic-reload=true` te permite rotar claves editando el archivo sin reiniciar el servidor de la API. Sin esa opción, cada cambio de clave requiere reiniciar el apiserver.

En un clúster HA, aplicá el archivo de configuración **idéntico** a cada nodo del plano de control antes de confiar en él — de lo contrario un servidor de la API no podrá descifrar lo que otro escribió.

### Paso 4 — demostrar que funciona

Creá un Secret nuevo y leé el valor crudo de etcd:

```bash
kubectl create secret generic enc-test --from-literal=password=topsecret

ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/default/enc-test | hexdump -C | head -5
```

Cifrado (fijate en el prefijo `k8s:enc:aescbc:v1:key1:` y en que no hay ningún valor legible):

```
00000000  2f 72 65 67 69 73 74 72  79 2f 73 65 63 72 65 74  |/registry/secret|
00000010  73 2f 64 65 66 61 75 6c  74 2f 65 6e 63 2d 74 65  |s/default/enc-te|
00000020  73 74 0a 6b 38 73 3a 65  6e 63 3a 61 65 73 63 62  |st.k8s:enc:aescb|
00000030  63 3a 76 31 3a 6b 65 79  31 3a 1d 4f b7 a9 6c 22  |c:v1:key1:.O..l"|
00000040  8e 33 0b c5 71 fa 20 db  9c 47 e1 5a 3f 08 62 d4  |.3..q. ..G.Z?.b.|
```

Un Secret **sin cifrar** se ve así en cambio — el valor está ahí a la vista:

```
00000000  2f 72 65 67 69 73 74 72  79 2f 73 65 63 72 65 74  |/registry/secret|
...
00000060  70 61 73 73 77 6f 72 64  12 09 74 6f 70 73 65 63  |password..topsec|
00000070  72 65 74                                          |ret|
```

### Paso 5 — recifrar los Secrets preexistentes

El cifrado sólo se aplica al escribir. Los Secrets existentes quedan en texto plano hasta que se reescriben:

```bash
kubectl get secrets --all-namespaces -o json | kubectl replace -f -
```

```
secret/db-creds replaced
secret/regcred replaced
...
```

Si cifraste también otros recursos, ejecutá el equivalente para cada uno (`kubectl get configmaps -A -o json | kubectl replace -f -`).

### Rotación de claves

1. Agregá la clave nueva como **segunda** entrada bajo el proveedor existente y recargá/reiniciá todos los servidores de la API (todos los servidores deben poder *descifrar* con la clave nueva antes de que cualquiera de ellos *cifre* con ella).
2. Movés la clave nueva a la **primera** posición; recargá/reiniciá de nuevo — las escrituras nuevas ya la usan.
3. Recifrá todo: `kubectl get secrets -A -o json | kubectl replace -f -`.
4. Quitá la clave vieja y recargá/reiniciá una última vez.

```yaml
      - aescbc:
          keys:
            - name: key2   # new — now the write key
              secret: <new-32-byte-base64>
            - name: key1   # old — kept only for decryption
              secret: <old-32-byte-base64>
```

Saltarse esta coreografía de orden en un clúster HA provoca `Internal error occurred: ... no matching key was found for the provided keyID` en las lecturas.

### Lo que el cifrado en reposo *no* protege

- La ruta de red de etcd (usá TLS de peer/cliente de etcd: `--cert-file`, `--key-file`, `--peer-*`, `--client-cert-auth=true`).
- Cualquiera con acceso de lectura a Secrets por la API — el servidor de la API descifra de forma transparente para esa persona.
- El archivo de clave en sí en el nodo del plano de control (mitigalo con KMS).
- Backups de etcd tomados *antes* del recifrado.

---

## 7. Almacenes de secretos externos

La postura más fuerte es mantener el material sensible fuera de etcd por completo.

**Secrets Store CSI Driver** — monta secretos desde un proveedor externo (Vault, AWS Secrets Manager, Azure Key Vault, GCP Secret Manager) directamente en el Pod como un volumen `tmpfs`:

```yaml
  volumes:
    - name: secrets
      csi:
        driver: secrets-store.csi.k8s.io
        readOnly: true
        volumeAttributes:
          secretProviderClass: vault-db-creds
```

Propiedades que vale la pena citar en una respuesta de examen:
- Los valores se obtienen al arrancar el Pod y el driver puede rotarlos; nada se persiste en etcd salvo que habilites explícitamente la sincronización de secretos.
- El Pod se autentica ante el proveedor con su **token proyectado de ServiceAccount** (vinculado a audiencia), así que no hay credencial de bootstrap que pueda filtrarse.
- El acceso es auditable y revocable en el sistema externo, con independencia del RBAC de Kubernetes.

**External Secrets Operator / Vault Agent Injector** son el patrón alternativo: *sí* materializan un Secret de Kubernetes (ESO) o inyectan archivos mediante un sidecar (Vault Agent). ESO te da gestión y rotación centralizadas, pero mantiene la exposición en etcd — así que el cifrado en reposo sigue importando.

**Higiene de GitOps:** nunca subas manifiestos de Secret en crudo. Usá SOPS, Sealed Secrets, o una referencia a un almacén (`ExternalSecret`, `SecretProviderClass`) para que el repositorio contenga sólo texto cifrado o punteros.

---

## 8. Detectar y auditar el acceso a Secrets

Auditá el acceso a Secrets únicamente a nivel `Metadata`. Usar `Request` o `RequestResponse` para secrets escribe los valores de los secretos en el log de auditoría — una brecha autoinfligida:

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
  - RequestReceived
rules:
  # Never log bodies for these
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]
      - group: "authentication.k8s.io"
        resources: ["tokenreviews"]
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["pods"]
```

Buscar problemas:

```bash
# Who can read secrets cluster-wide?
kubectl get clusterrolebindings -o json \
  | jq -r '.items[] | select(.roleRef.name=="cluster-admin") | .metadata.name'

# Roles granting list/watch on secrets
kubectl get roles,clusterroles -A -o json \
  | jq -r '.items[] | select(.rules[]? | (.resources[]?=="secrets") and (.verbs[]? | IN("list","watch","*"))) | "\(.kind)/\(.metadata.namespace // "-")/\(.metadata.name)"'

# Legacy long-lived SA token Secrets
kubectl get secrets -A --field-selector type=kubernetes.io/service-account-token
```

Revisá también si hay secretos filtrándose por los canales equivocados: `command`/`args` en las specs de Pods, ConfigMaps usados como pseudo-Secrets, anotaciones, capas de la imagen del contenedor (`docker history`) y logs de CI.

---

## 9. Checklist de hardening

1. Habilitá el cifrado en reposo para `secrets` (KMS v2 en producción, proveedor local en caso contrario) y recifrá los objetos existentes.
2. Habilitá `--authorization-mode=Node,RBAC` más el plugin de admisión `NodeRestriction`.
3. Nada de `list`/`watch` sobre `secrets` para las identidades de las cargas de trabajo; delimitá `get` con `resourceNames`.
4. Tratá los permisos de creación de Pods en un namespace como acceso de lectura a los Secrets de ese namespace; separá las cargas de trabajo sensibles por namespace.
5. Preferí los montajes de volumen sobre las variables de entorno; poné `defaultMode: 0400` y `readOnly: true`, y proyectá sólo los `items` necesarios.
6. Poné `automountServiceAccountToken: false` allí donde no se use la API; usá tokens proyectados, vinculados a audiencia y de vida corta en el resto.
7. Eliminá los Secrets legacy de tipo `kubernetes.io/service-account-token`.
8. Marcá los Secrets estables con `immutable: true`.
9. Protegé el propio etcd: TLS de cliente/peer, `--client-cert-auth=true`, backups cifrados y con control de acceso, permisos de archivo a nivel de host sobre `/etc/kubernetes/enc`.
10. Auditá el acceso a Secrets a nivel `Metadata`; nunca registres los cuerpos de las peticiones para secrets.
11. Mantené los secretos fuera de Git, de las imágenes, de `args` y de los logs de la aplicación.

---

## Referencias

- CKS Curriculum v1.34 (CNCF): https://github.com/cncf/curriculum
- Secrets (concepts): https://kubernetes.io/docs/concepts/configuration/secret/
- Good practices for Kubernetes Secrets: https://kubernetes.io/docs/concepts/security/secrets-good-practices/
- Managing Secrets using kubectl: https://kubernetes.io/docs/tasks/configmap-secret/managing-secret-using-kubectl/
- Managing Secrets using Configuration File: https://kubernetes.io/docs/tasks/configmap-secret/managing-secret-using-config-file/
- Distribute Credentials Securely Using Secrets: https://kubernetes.io/docs/tasks/inject-data-application/distribute-credentials-secure/
- Encrypting Confidential Data at Rest: https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
- Using a KMS provider for data encryption: https://kubernetes.io/docs/tasks/administer-cluster/kms-provider/
- EncryptionConfiguration API reference: https://kubernetes.io/docs/reference/config-api/apiserver-config.v1/
- Configure Service Accounts for Pods: https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/
- Managing Service Accounts: https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/
- Using RBAC Authorization: https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Node Authorization: https://kubernetes.io/docs/reference/access-authn-authz/node/
- Using Admission Controllers (`NodeRestriction`): https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#noderestriction
- Auditing: https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Projected Volumes: https://kubernetes.io/docs/concepts/storage/projected-volumes/
- Pull an Image from a Private Registry: https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/
- Secrets Store CSI Driver: https://secrets-store-csi-driver.sigs.k8s.io/
- Operating etcd clusters for Kubernetes: https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/