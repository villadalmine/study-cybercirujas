# 2.2 Manage Kubernetes Secrets

## ¿Por qué los Secrets requieren atención especial?

Un `Secret` en Kubernetes es, por defecto, **solo un ConfigMap con los valores codificados en base64**. Esto es una codificación, no un cifrado: cualquiera con acceso de lectura al objeto puede decodificarlo trivialmente.

```bash
kubectl create secret generic db-creds \
  --from-literal=username=admin \
  --from-literal=password='S3cr3t!'

kubectl get secret db-creds -o jsonpath='{.data.password}' | base64 -d
# S3cr3t!
```

Desde la perspectiva de CKS, "manage secrets" implica endurecer tres capas distintas:

1. **Almacenamiento** — cómo se guardan en `etcd`.
2. **Acceso** — quién/qué puede leerlos vía API o filesystem del Pod.
3. **Distribución** — cómo llegan a los contenedores sin quedar expuestos.

---

## 1. Almacenamiento: cifrado en reposo (encryption at rest)

Por default, `etcd` guarda los Secrets **en texto plano** (codificados en base64, sin cifrar). Cualquiera con acceso al filesystem del nodo control-plane o a un backup de `etcd` puede leerlos directamente.

### EncryptionConfiguration

Se habilita pasando un archivo `--encryption-provider-config` al `kube-apiserver`.

```yaml
# /etc/kubernetes/enc/enc.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: <base64-encoded-32-byte-key>
      - identity: {}   # fallback: permite leer datos ya existentes sin cifrar
```

```yaml
# /etc/kubernetes/manifests/kube-apiserver.yaml (fragmento)
spec:
  containers:
    - command:
        - kube-apiserver
        - --encryption-provider-config=/etc/kubernetes/enc/enc.yaml
      volumeMounts:
        - mountPath: /etc/kubernetes/enc
          name: enc-config
          readOnly: true
  volumes:
    - name: enc-config
      hostPath:
        path: /etc/kubernetes/enc
```

Como `kube-apiserver` corre como Static Pod, kubelet lo reinicia automáticamente al detectar el cambio.

**Puntos clave para el examen:**

- Los providers se aplican en orden; el primero de la lista es el usado para **escribir**, todos se prueban para **leer** (útil durante una migración).
- `identity` sin cifrado nunca debe ser el primero en producción, pero se deja al final como fallback de lectura.
- Habilitar el cifrado **no re-cifra los Secrets existentes**. Hay que forzar una reescritura:

```bash
kubectl get secrets --all-namespaces -o json | kubectl replace -f -
```

- Verificar que ya no están en texto plano leyendo directamente `etcd`:

```bash
ETCDCTL_API=3 etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/default/db-creds | hexdump -C | head
# debería verse el prefijo del provider (ej: k8s:enc:aescbc:v1:key1:...) en vez del valor plano
```

- Alternativa más robusta (mencionada en el curriculum): usar un **KMS provider** (`kms v2`) que delega el cifrado de la DEK a un servicio externo (AWS KMS, HashiCorp Vault Transit, etc.), evitando guardar la clave en disco del control-plane.

---

## 2. Acceso: RBAC y superficie de exposición

El cifrado en reposo no sirve de nada si cualquier `ServiceAccount` puede leer Secrets vía API. Aplicar **least privilege**:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: prod
  name: secret-reader
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get"]
    resourceNames: ["db-creds"]   # restringe a un Secret puntual, no a todos
```

```bash
kubectl auth can-i get secrets --as=system:serviceaccount:prod:web-app -n prod
# yes / no
```

Otros vectores a auditar:

- **`get`/`list`/`watch` de pods**: quien puede hacer `exec` en un Pod que monta un Secret puede leerlo desde el filesystem del contenedor, aunque no tenga permiso directo sobre el objeto `Secret`.
- **`clusterrolebinding` a `cluster-admin`** por defecto en ServiceAccounts (revisar `kubectl get clusterrolebindings -o wide`).
- Habilitar el **Audit Log** de la API sobre el recurso `secrets` para detectar accesos anómalos (cubierto en el dominio de Monitoring/Logging, pero relevante acá).

---

## 3. Distribución: cómo se consumen en los Pods

### Variables de entorno (evitar cuando sea posible)

```yaml
env:
  - name: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: db-creds
        key: password
```

Riesgo: las env vars quedan visibles en `kubectl describe pod`, en `/proc/<pid>/environ` dentro del contenedor, y suelen filtrarse en logs de crash o herramientas de debugging.

### Volumen montado (preferido)

```yaml
volumes:
  - name: creds-vol
    secret:
      secretName: db-creds
      defaultMode: 0440
containers:
  - name: app
    volumeMounts:
      - name: creds-vol
        mountPath: /etc/creds
        readOnly: true
```

Se monta como `tmpfs` (en memoria, no en disco), y el archivo puede rotar sin reiniciar el Pod si la app hace polling.

### `subPath` rompe la rotación

Si se monta con `subPath`, kubelet **no** actualiza el archivo cuando el Secret cambia. Evitar `subPath` si se necesita rotación en caliente.

---

## 4. Endurecimientos adicionales

### Secrets inmutables

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-creds
immutable: true
data:
  password: UzNjcjN0IQ==
```

`immutable: true` evita cambios accidentales/maliciosos posteriores a los datos u obliga a recrear el objeto (con nuevo nombre) para rotarlo. Ventaja adicional: `kube-apiserver` no reevalúa `watch`es sobre ese Secret en cada actualización, reduciendo carga.

### Evitar Secrets en manifiestos versionados

No commitear YAML con `data`/`stringData` en Git. Usar herramientas de gestión externa mencionadas en el curriculum:

- **Sealed Secrets** (Bitnami): cifra el Secret con una clave pública del controller; el YAML resultante (`SealedSecret`) es seguro de versionar.
- **External Secrets Operator / HashiCorp Vault**: el Secret real vive en un vault externo; en el cluster solo existe una referencia que un operator sincroniza en tiempo de ejecución.

```bash
# ejemplo con kubeseal
kubeseal --format=yaml < secret.yaml > sealed-secret.yaml
kubectl apply -f sealed-secret.yaml
```

### Rotación

Rotar credenciales periódicamente y tras cualquier incidente. Al usar volúmenes (no `subPath`), kubelet propaga el nuevo valor en segundos sin reiniciar el Pod; la aplicación debe recargarlo (poll o inotify).

---

## Checklist rápido para el examen

- [ ] `EncryptionConfiguration` habilitado y aplicado (`--encryption-provider-config`) en el `kube-apiserver`.
- [ ] Secrets existentes re-escritos tras habilitar cifrado (`kubectl replace`).
- [ ] RBAC restringe `get/list/watch` sobre `secrets` a lo mínimo necesario, idealmente con `resourceNames`.
- [ ] Preferir volúmenes sobre env vars para inyectar Secrets.
- [ ] No usar `subPath` si se necesita rotación.
- [ ] `immutable: true` en Secrets que no deben cambiar en caliente.
- [ ] Nada de Secrets en texto plano en Git; usar Sealed Secrets / Vault / External Secrets Operator.

---

## Referencias

- Kubernetes Secrets — https://kubernetes.io/docs/concepts/configuration/secret/
- Encrypting Confidential Data at Rest — https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
- Using a KMS provider for data encryption — https://kubernetes.io/docs/tasks/administer-cluster/kms-provider/
- Managing Secrets using kubectl — https://kubernetes.io/docs/tasks/configmap-secret/managing-secret-using-kubectl/
- RBAC Authorization — https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Sealed Secrets (Bitnami) — https://github.com/bitnami-labs/sealed-secrets
- External Secrets Operator — https://external-secrets.io/
- CKS Curriculum v1.34 — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf