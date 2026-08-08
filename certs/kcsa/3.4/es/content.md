# Secrets — Seguridad, almacenamiento y ciclo de vida de credenciales en Kubernetes

> **Dominio KCSA:** Kubernetes Security Fundamentals · **Tema 3.4** · **Peso:** 3.14
> Perfil: gestión de material sensible, superficie de exposición, cifrado en reposo y delegación a gestores externos.

---

## 1. Motivación y el problema arquitectónico de producción

Toda carga de trabajo real necesita **material sensible**: contraseñas de bases de datos, tokens de API, claves privadas TLS, credenciales de registries. El problema arquitectónico no es "dónde guardo el password", sino **cómo lo distribuyo a N Pods, en M nodos, sin filtrarlo en el camino y sin acoplarlo a la imagen**.

Las tres soluciones ingenuas y por qué fallan en producción:

| Enfoque ingenuo | Por qué falla (modelo de amenaza) |
|---|---|
| **Hardcodear en la imagen** (`ENV DB_PASS=...` en el `Dockerfile`) | La credencial queda en las capas del registry, versionada e inmutable; cualquiera con `docker pull` la extrae con `docker history`. Rotar exige rebuild + redeploy. |
| **Guardar en un ConfigMap** | Un ConfigMap es texto plano diseñado para configuración *no sensible*. No hay separación de RBAC, ni cifrado en reposo, ni tratamiento especial del kubelet. Aparece en logs de auditoría y en `describe`. |
| **Montar desde un archivo en el nodo / hostPath** | Rompe la portabilidad, acopla el Pod al nodo y expone el secreto a cualquier contenedor con acceso al filesystem del host. |

Kubernetes introduce el objeto **`Secret`** para desacoplar la credencial del Pod y de la imagen. Pero acá está el punto que el KCSA evalúa una y otra vez:

> **Un `Secret` de Kubernetes NO es un mecanismo de cifrado.** Su contenido se almacena **codificado en base64**, que es reversible por cualquiera. La palabra "secret" describe la *intención* (tratamiento diferenciado, RBAC dedicado, montaje en `tmpfs`), no una garantía criptográfica por defecto.

### El problema real: `etcd` en texto plano

Por defecto, `kube-apiserver` persiste los `Secret` en `etcd` **tal cual**, solo con el valor en base64. Esto significa que **el modelo de amenaza no es "el atacante lee el YAML", sino cualquiera de estos caminos**:

```
┌─────────────────────────────────────────────────────────────┐
│                  Superficie de exposición de un Secret       │
├─────────────────────────────────────────────────────────────┤
│ 1. etcd en reposo    → snapshot / backup / robo de disco     │
│ 2. etcd en tránsito  → tráfico apiserver↔etcd sin mTLS       │
│ 3. API de Kubernetes → RBAC excesivo (get/list/watch)        │
│ 4. Env vars del Pod  → /proc/PID/environ, crash dumps, logs  │
│ 5. Acceso al nodo    → tmpfs del kubelet, credenciales SA    │
│ 6. Escalado vía RBAC → crear Pods que monten cualquier Secret│
└─────────────────────────────────────────────────────────────┘
```

El objetivo de este tema es **cerrar cada uno de esos seis caminos**: cifrado en reposo (1,2), RBAC de mínimo privilegio (3,6), preferir volúmenes sobre env vars (4), y delegar a un gestor externo cuando el nivel de garantía lo exige (5).

---

## 2. Anatomía de un Secret y sus tipos

Un `Secret` es un objeto namespaced. El campo `data` contiene pares clave/valor donde **el valor está en base64**; `stringData` es azúcar de escritura (se acepta texto plano y el apiserver lo codifica).

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
  namespace: payments
type: Opaque
data:
  username: cGF5bWVudHM=          # "payments" en base64
  password: UzNjdXIzUEBzcyE=      # "S3cur3P@ss!" en base64
stringData:
  connection-string: "postgres://payments@db:5432/ledger"  # se codifica solo
```

### Tipos incorporados (`type:`)

El campo `type` no es cosmético: condiciona qué **claves** exige el apiserver y cómo lo consumen ciertos componentes (kubelet, container runtime).

| `type` | Claves requeridas | Uso |
|---|---|---|
| `Opaque` | arbitrarias | genérico (default) |
| `kubernetes.io/service-account-token` | anotación `kubernetes.io/service-account.name` | token de ServiceAccount (legado; ver §nota 1.24+) |
| `kubernetes.io/dockercfg` | `.dockercfg` | credenciales de registry (formato legado) |
| `kubernetes.io/dockerconfigjson` | `.dockerconfigjson` | credenciales de registry (`imagePullSecrets`) |
| `kubernetes.io/basic-auth` | `username`, `password` | autenticación básica |
| `kubernetes.io/ssh-auth` | `ssh-privatekey` | clave privada SSH |
| `kubernetes.io/tls` | `tls.crt`, `tls.key` | certificado + clave TLS (Ingress, mTLS) |
| `bootstrap.kubernetes.io/token` | `token-id`, `token-secret` | bootstrap tokens de kubeadm |

> **Cambio de seguridad relevante (v1.24+):** ya **no** se crea automáticamente un `Secret` de tipo `service-account-token` por cada ServiceAccount. El patrón recomendado es la **TokenRequest API** con tokens de vida corta, audience-scoped y auto-rotados, proyectados vía `projected volume`. Un token de SA en un `Secret` es de vida ilimitada y no rota: es un pasivo de seguridad.

### Restricciones y endurecimiento

- **Tamaño máximo:** 1 MiB por `Secret` (evita agotar memoria del apiserver/etcd).
- **`immutable: true`:** marca el `Secret` como inmutable. Beneficio doble: previene actualizaciones accidentales/maliciosas y **reduce carga en el apiserver** (el kubelet deja de hacer watch sobre él).

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
  namespace: payments
type: Opaque
immutable: true          # no se puede modificar; solo borrar y recrear
data:
  password: UzNjdXIzUEBzcyE=
```

---

## 3. Consumo: variables de entorno vs. volúmenes (decisión de seguridad)

Cómo un Pod recibe el secreto **es una decisión de seguridad, no de conveniencia**. Es uno de los trade-offs más preguntados del tema.

| Criterio | `env` (variable de entorno) | `volume` (montaje de archivo) |
|---|---|---|
| Exposición vía `/proc/<pid>/environ` | **Sí** — legible por cualquier proceso con el mismo UID | No |
| Filtrado en logs / crash dumps / APM | **Alto** — muchos frameworks vuelcan el env completo | Bajo |
| Herencia a procesos hijos | **Sí** — se propaga a todo `fork/exec` | No |
| Actualización sin reiniciar el Pod | **No** — el valor se fija al arranque | **Sí** — el kubelet refresca el archivo (~1 min) |
| Almacenamiento en el nodo | env del proceso | **`tmpfs` (RAM)** — nunca toca disco |
| `subPath` refresca automáticamente | n/a | **No** — `subPath` congela el valor |

**Recomendación de producción:** preferir **volúmenes** salvo que la aplicación no soporte leer de archivo. El kubelet monta los volúmenes de `Secret` en un `tmpfs` respaldado por memoria, de modo que **el secreto nunca se escribe al disco del nodo**.

### Manifiesto completo: ambas formas de consumo

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ledger-api
  namespace: payments
spec:
  replicas: 2
  selector:
    matchLabels: { app: ledger-api }
  template:
    metadata:
      labels: { app: ledger-api }
    spec:
      automountServiceAccountToken: false   # no montar token de SA si no se usa
      containers:
        - name: api
          image: registry.example.com/ledger-api:1.8.3
          # --- Opción A: variable de entorno (menos segura) ---
          env:
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: db-credentials
                  key: password
          # --- Opción B: volumen (preferida) ---
          volumeMounts:
            - name: db-creds
              mountPath: /etc/secrets/db
              readOnly: true
      volumes:
        - name: db-creds
          secret:
            secretName: db-credentials
            defaultMode: 0400            # solo lectura, solo el owner
            items:
              - key: password
                path: password           # se expone /etc/secrets/db/password
      imagePullSecrets:
        - name: registry-creds           # Secret dockerconfigjson
```

---

## 4. Cifrado en reposo — cerrar el camino de `etcd`

Este es el control técnico central del tema. Sin él, cualquiera que obtenga un **snapshot de etcd** (backup, robo de volumen, acceso al nodo del control plane) lee todos los secretos en base64.

Se habilita con el flag `--encryption-provider-config` en **`kube-apiserver`**, apuntando a un objeto `EncryptionConfiguration`.

### Comparativa de providers

| Provider | Algoritmo | Cifra en reposo | Rotación de clave | Notas de seguridad |
|---|---|---|---|---|
| `identity` | ninguno | **No** | n/a | Default. Texto plano (base64). |
| `aescbc` | AES-CBC + PKCS#7 | Sí | manual | Vulnerable a padding oracle en teoría; ya no recomendado como primera opción. |
| `aesgcm` | AES-GCM | Sí | **obligatoria y frecuente** | El más rápido, pero reusar nonce es catastrófico: solo si automatizás rotación. |
| `secretbox` | XSalsa20 + Poly1305 | Sí | manual | Buena opción local, moderno. |
| `kms` (v2) | envelope encryption | Sí | **automática, sin downtime** | **Recomendado en producción.** La KEK vive en un KMS externo (Vault, AWS/GCP/Azure KMS); Kubernetes solo maneja DEKs. |

> **Regla de oro:** la clave del provider local (`aescbc`/`secretbox`) queda **en texto plano en el filesystem del control plane** (`/etc/kubernetes/enc/`). Protege contra el robo del *disco de etcd*, no contra el robo del *nodo del apiserver*. Para separar esos dos ámbitos se usa **KMS v2** (envelope): la Key Encryption Key nunca sale del HSM/KMS.

### 4.1 EncryptionConfiguration con clave local (`aescbc`)

```yaml
# /etc/kubernetes/enc/encryption-config.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      # El PRIMER provider cifra las escrituras nuevas.
      - aescbc:
          keys:
            - name: key1
              # openssl rand -base64 32
              secret: c2VjcmV0LWtleS0zMi1ieXRlcy1sb25nLWJhc2U2NA==
      # 'identity' al final permite leer secretos aún NO cifrados (migración).
      - identity: {}
```

Se referencia en el manifiesto estático del apiserver:

```yaml
# /etc/kubernetes/manifests/kube-apiserver.yaml (extracto)
spec:
  containers:
    - name: kube-apiserver
      command:
        - kube-apiserver
        - --encryption-provider-config=/etc/kubernetes/enc/encryption-config.yaml
        - --encryption-provider-config-automatic-reload=true
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

### 4.2 EncryptionConfiguration con KMS v2 (producción)

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - kms:
          apiVersion: v2
          name: vault-kms-plugin
          endpoint: unix:///var/run/kmsplugin/socket.sock
          timeout: 3s
      - identity: {}
```

### 4.3 Migrar los secretos existentes

Habilitar el cifrado **no cifra retroactivamente** lo que ya está en etcd; solo afecta escrituras nuevas. Hay que reescribir cada secreto:

```bash
# Reescribe TODOS los secretos → se persisten cifrados con el provider activo
$ kubectl get secrets --all-namespaces -o json \
    | kubectl replace -f -
secret/db-credentials replaced
secret/registry-creds replaced
...
```

Una vez confirmado que todo está cifrado (§5), se puede quitar el provider `identity` para que el apiserver **rechace** leer datos en texto plano — garantía de que no queda ningún residuo sin cifrar.

---

## 5. Verificación y diagnóstico de fallas

### 5.1 Comprobar que un Secret está realmente cifrado en etcd

La única prueba concluyente es **leer el blob crudo desde etcd**:

```bash
$ sudo ETCDCTL_API=3 etcdctl \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    get /registry/secrets/payments/db-credentials | hexdump -C | head
```

**Antes de habilitar cifrado** — se lee el valor en claro:

```
00000000  2f 72 65 67 69 73 74 72  79 2f 73 65 63 72 65 74  |/registry/secret|
00000010  73 2f 70 61 79 6d 65 6e  74 73 2f 64 62 2d 63 72  |s/payments/db-cr|
...
000000a0  53 33 63 75 72 33 50 40  73 73 21 0a               |S3cur3P@ss!.|   ← PASSWORD EN CLARO
```

**Después de habilitar `aescbc`** — se lee el prefijo del provider y datos binarios:

```
00000000  2f 72 65 67 69 73 74 72  79 2f 73 65 63 72 65 74  |/registry/secret|
...
00000050  6b 38 73 3a 65 6e 63 3a  61 65 73 63 62 63 3a 76  |k8s:enc:aescbc:v|
00000060  31 3a 6b 65 79 31 3a 8f  1c 4a e2 7b d9 ...        |1:key1:..J.{..  |   ← blob cifrado
```

El marcador **`k8s:enc:aescbc:v1:key1:`** confirma cifrado activo. Si aparece el texto legible, **no está cifrado** (revisá el orden de providers o si faltó el `kubectl replace`).

### 5.2 Auditar quién puede leer secretos (RBAC)

`get`, `list` y `watch` sobre `secrets` **devuelven el contenido completo**. `list` es especialmente peligroso: expone *todos* los secretos del namespace de una.

```bash
# ¿Puede esta ServiceAccount leer secretos?
$ kubectl auth can-i list secrets \
    --namespace payments \
    --as=system:serviceaccount:payments:ledger-api
no

# ¿Qué subjects tienen acceso a secrets en el cluster? (revisión de bindings)
$ kubectl get clusterrolebindings,rolebindings -A -o json \
    | jq -r '.items[] | select(.roleRef.name|test("secret";"i")) | .metadata.name'
```

**Vector de escalado clave (muy preguntado):** un usuario con permiso para **crear Pods o Deployments** en un namespace puede montar **cualquier** `Secret` de ese namespace, aunque no tenga `get secrets`. Basta con crear un Pod que lo monte y leer el archivo. Por eso `create pods` es efectivamente equivalente a leer todos los secretos del namespace.

### 5.3 Detectar secretos filtrados en variables de entorno

```bash
# ¿Hay secretos inyectados como env vars? (superficie de /proc/environ)
$ kubectl get pods -A -o json | jq -r '
    .items[] | .metadata.namespace as $ns | .metadata.name as $p
    | .spec.containers[]
    | select(.env[]?.valueFrom.secretKeyRef != null)
    | "\($ns)/\($p): \(.name)"'
payments/ledger-api-7d9f...: api      ← candidato a migrar a volumen
```

### 5.4 RBAC de mínimo privilegio para un Secret puntual

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: payments
  name: read-db-credentials
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get"]                        # 'get', NO 'list' — sin enumeración masiva
    resourceNames: ["db-credentials"]     # un único Secret, no todos
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  namespace: payments
  name: ledger-reads-db-creds
subjects:
  - kind: ServiceAccount
    name: ledger-api
    namespace: payments
roleRef:
  kind: Role
  name: read-db-credentials
  apiGroup: rbac.authorization.k8s.io
```

> **Limitación de `resourceNames`:** funciona con `get`/`update`/`delete`, **no con `list`/`watch`** (esos verbos no aceptan filtrado por nombre). Es la razón técnica para preferir `get` sobre `list` en roles de aplicación.

### 5.5 Tabla de diagnóstico de fallas frecuentes

| Síntoma | Causa probable | Verificación / arreglo |
|---|---|---|
| `CreateContainerConfigError` en el Pod | el `Secret` referenciado no existe o falta la key | `kubectl describe pod` → evento `secret "X" not found`; revisar `secretKeyRef.key` |
| Env var vacía pero el Pod arranca | `optional: true` en `secretKeyRef` y la key falta | quitar `optional` o corregir la key |
| El archivo montado no se actualiza | uso de `subPath` (congela el valor) o `immutable: true` | montar el directorio sin `subPath` |
| etcd sigue en texto plano tras configurar cifrado | falta el `kubectl replace`, o `identity` quedó primero | reordenar providers; reescribir con `get -o json \| replace -f -` |
| `ImagePullBackOff` con registry privado | falta `imagePullSecrets` o tipo incorrecto | usar `kubernetes.io/dockerconfigjson`; asociar al SA o al Pod |
| Token de SA no rota / vida infinita | `Secret` de tipo `service-account-token` legado | migrar a `projected` token (TokenRequest) |

---

## 6. Delegar a gestores externos — cuándo Secrets nativos no alcanzan

Los `Secret` nativos, incluso cifrados, tienen límites: **la fuente de verdad sigue siendo etcd**, no hay auditoría de acceso granular a nivel de credencial, ni rotación dinámica, ni leasing. En entornos regulados se delega a un gestor externo. Comparativa de patrones:

| Patrón | Fuente de verdad | Rotación | GitOps-friendly | Modelo |
|---|---|---|---|---|
| **Secret nativo + cifrado en reposo** | etcd | manual | no (secreto en claro en el repo) | baseline |
| **Sealed Secrets** (Bitnami) | Git (cifrado) | manual | **sí** — el `SealedSecret` cifrado se commitea | controller descifra con clave del cluster → produce un `Secret` |
| **SOPS** (+ Flux/Argo) | Git (cifrado) | manual | **sí** | descifrado en el pipeline/controller con KMS/age/PGP |
| **External Secrets Operator** | Vault / AWS SM / GCP SM / Azure KV | **sí** (sincroniza) | sí (solo referencias) | el operator lee del backend y materializa un `Secret` |
| **Secrets Store CSI Driver** | Vault / cloud KMS | **sí** | sí | monta el secreto directo en el volumen; puede *no* crear `Secret` en etcd |

### 6.1 Sealed Secrets — secreto cifrado, seguro para commitear

```yaml
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: db-credentials
  namespace: payments
spec:
  encryptedData:
    # Cifrado con la clave PÚBLICA del controller; solo el cluster lo descifra.
    password: AgBy8hCF8...很长的base64...Q2z9k=
  template:
    metadata:
      name: db-credentials
      namespace: payments
    type: Opaque
```

```bash
# Se genera con kubeseal a partir de un Secret normal (que nunca se commitea):
$ kubectl create secret generic db-credentials \
    --from-literal=password='S3cur3P@ss!' \
    --dry-run=client -o yaml \
  | kubeseal --controller-namespace kube-system -o yaml > sealed-db.yaml
# sealed-db.yaml SÍ se commitea: sin la clave privada del cluster es inútil.
```

### 6.2 External Secrets Operator — sincronizar desde Vault

```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault-backend
  namespace: payments
spec:
  provider:
    vault:
      server: "https://vault.internal:8200"
      path: "kv"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "ledger-api"
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: db-credentials
  namespace: payments
spec:
  refreshInterval: "1h"              # re-sincroniza → habilita rotación
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: db-credentials             # Secret nativo que el operator materializa
    creationPolicy: Owner
  data:
    - secretKey: password
      remoteRef:
        key: payments/db             # ruta en Vault
        property: password
```

### 6.3 Secrets Store CSI Driver — montar sin persistir en etcd

```yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: vault-db-creds
  namespace: payments
spec:
  provider: vault
  parameters:
    roleName: "ledger-api"
    vaultAddress: "https://vault.internal:8200"
    objects: |
      - objectName: "password"
        secretPath: "kv/data/payments/db"
        secretKey: "password"
---
# En el Pod: el secreto se monta directo desde Vault, en tmpfs, sin crear un Secret.
apiVersion: v1
kind: Pod
metadata:
  name: ledger-api
  namespace: payments
spec:
  containers:
    - name: api
      image: registry.example.com/ledger-api:1.8.3
      volumeMounts:
        - name: secrets-store
          mountPath: "/mnt/secrets"
          readOnly: true
  volumes:
    - name: secrets-store
      csi:
        driver: secrets-store.csi.x-k8s.io
        readOnly: true
        volumeAttributes:
          secretProviderClass: "vault-db-creds"
```

---

## 7. Checklist de endurecimiento (resumen operativo)

1. **Cifrado en reposo activo** — `EncryptionConfiguration` con `kms` v2 (o `secretbox` local); verificado con `etcdctl` (§5.1).
2. **mTLS apiserver↔etcd** — cierra el camino de exposición en tránsito.
3. **RBAC de mínimo privilegio** — `get` con `resourceNames`, nunca `list` genérico; recordar que `create pods` ≈ leer todos los secretos del namespace.
4. **Preferir volúmenes sobre env vars** — evita `/proc/environ`, logs y herencia a hijos.
5. **`automountServiceAccountToken: false`** salvo necesidad; migrar tokens legados a `projected` (TokenRequest).
6. **`immutable: true`** en secretos estables — previene mutación y reduce carga del apiserver.
7. **`defaultMode: 0400`** en montajes — solo lectura, solo el owner.
8. **Auditoría** — habilitar audit logs, pero **filtrar el body de recursos `secrets`** para no filtrar el propio secreto en el log.
9. **Gestor externo** (ESO/CSI/Vault) cuando se requiere rotación dinámica, leasing o separar la fuente de verdad de etcd.
10. **Nunca commitear un `Secret` en claro** — usar Sealed Secrets o SOPS para GitOps.

---

## 8. Referencias

- Kubernetes — Secrets (concepto): https://kubernetes.io/docs/concepts/configuration/secret/
- Kubernetes — Good practices for Kubernetes Secrets: https://kubernetes.io/docs/concepts/security/secrets-good-practices/
- Kubernetes — Encrypting Confidential Data at Rest: https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
- Kubernetes — Using a KMS provider for data encryption: https://kubernetes.io/docs/tasks/administer-cluster/kms-provider/
- Kubernetes — Managing Service Accounts / TokenRequest: https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/
- Kubernetes — RBAC Authorization: https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Kubernetes — Distribute Credentials Securely Using Secrets: https://kubernetes.io/docs/tasks/inject-data-application/distribute-credentials-secure/
- CNCF — KCSA Curriculum: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
- Secrets Store CSI Driver: https://secrets-store-csi-driver.sigs.k8s.io/
- External Secrets Operator: https://external-secrets.io/latest/
- Sealed Secrets (Bitnami Labs): https://github.com/bitnami-labs/sealed-secrets
- HashiCorp Vault — Kubernetes auth: https://developer.hashicorp.com/vault/docs/auth/kubernetes