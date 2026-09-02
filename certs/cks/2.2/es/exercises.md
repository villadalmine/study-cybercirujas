# Tema 2.2 — Gestionar Secrets de Kubernetes: Ejercicios Guiados

**Certificación:** CKS (versión de examen 1.34) · **Peso en el examen:** 5

## Prerrequisitos del laboratorio

- Un clúster provisionado con kubeadm donde tengas **root/sudo en el nodo del plano de control** (vas a editar manifiestos de Pods estáticos y a leer etcd directamente).
- `kubectl`, `etcdctl` (o `ETCDCTL_API=3 etcdctl` mediante el contenedor de etcd), `jq`, `base64`, `openssl`.
- Un namespace de trabajo. Crealo una vez y reutilizalo en todos los ejercicios:

```bash
kubectl create namespace secret-lab
kubectl config set-context --current --namespace=secret-lab
```

> Todos los ejercicios son idempotentes: reejecutar un paso o bien tiene éxito o bien falla con "AlreadyExists", lo cual es seguro. Donde se edita un manifiesto se incluye un paso de backup para que puedas revertir.

---

## Ejercicio 1 — Demostrar que un Secret solo está codificado, no cifrado

### Pasos

1. Creá un Secret con dos claves, usando deliberadamente `-n` para evitar un salto de línea final en el valor:

   ```bash
   kubectl -n secret-lab create secret generic app-db \
     --from-literal=username=appuser \
     --from-literal=password='S3cr3t-P@ss'
   ```

2. Inspeccioná cómo lo almacena y lo devuelve el API server:

   ```bash
   kubectl -n secret-lab get secret app-db -o yaml
   ```

3. Decodificá una sola clave sin volcar el objeto entero:

   ```bash
   kubectl -n secret-lab get secret app-db -o jsonpath='{.data.password}' | base64 -d; echo
   ```

4. Compará con `describe`, que nunca imprime valores:

   ```bash
   kubectl -n secret-lab describe secret app-db
   ```

5. Ahora leé el registro crudo directamente de etcd en el nodo del plano de control:

   ```bash
   sudo ETCDCTL_API=3 etcdctl \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     --endpoints=https://127.0.0.1:2379 \
     get /registry/secrets/secret-lab/app-db | hexdump -C | head -n 20
   ```

6. Creá un segundo Secret usando `stringData` en lugar de `data`, y después leelo:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Secret
   metadata:
     name: app-api
     namespace: secret-lab
   type: Opaque
   stringData:
     apikey: "ak-1234567890"
   EOF

   kubectl -n secret-lab get secret app-api -o yaml | grep -A2 '^data:'
   ```

### Verificá tu comprensión

- **P1.1** En el paso 5, ¿era visible `S3cr3t-P@ss` en la salida de etcd? ¿Qué te dice eso sobre el nivel de protección por defecto de los Secrets?
- **P1.2** ¿Por qué `base64` no es un control de seguridad acá?
- **P1.3** `describe` ocultó los valores pero `get -o yaml` los mostró. ¿Qué verbo de RBAC necesitan ambas operaciones, y qué implica eso respecto del acceso "de solo lectura" a los Secrets?
- **P1.4** ¿Qué pasó con el campo `stringData` después del `apply`? ¿Qué campo gana si tanto `data` como `stringData` definen la misma clave?
- **P1.5** ¿Por qué las instrucciones insistieron en la semántica de `--from-literal` / `echo -n` en lugar de `--from-file=password.txt` creado con `echo`?

---

## Ejercicio 2 — Habilitar el cifrado en reposo para los Secrets

### Pasos

1. Respaldá el manifiesto actual del API server y los datos de etcd antes de tocar nada:

   ```bash
   sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.bak
   sudo ETCDCTL_API=3 etcdctl \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     --endpoints=https://127.0.0.1:2379 \
     snapshot save /root/etcd-before-encryption.db
   ```

2. Generá una clave de 32 bytes y escribí el `EncryptionConfiguration`:

   ```bash
   sudo mkdir -p /etc/kubernetes/enc
   KEY=$(head -c 32 /dev/urandom | base64)

   sudo tee /etc/kubernetes/enc/enc.yaml >/dev/null <<EOF
   apiVersion: apiserver.config.k8s.io/v1
   kind: EncryptionConfiguration
   resources:
     - resources:
         - secrets
       providers:
         - secretbox:
             keys:
               - name: key1
                 secret: ${KEY}
         - identity: {}
   EOF

   sudo chmod 600 /etc/kubernetes/enc/enc.yaml
   ```

3. Conectá el archivo al Pod estático del API server. Agregá los flags bajo `command:`:

   ```yaml
       - --encryption-provider-config=/etc/kubernetes/enc/enc.yaml
       - --encryption-provider-config-automatic-reload=true
   ```

   Agregá el volume mount al contenedor `kube-apiserver`:

   ```yaml
       volumeMounts:
         - name: enc
           mountPath: /etc/kubernetes/enc
           readOnly: true
   ```

   Y el volumen del host a nivel de Pod:

   ```yaml
     volumes:
       - name: enc
         hostPath:
           path: /etc/kubernetes/enc
           type: DirectoryOrCreate
   ```

4. Guardá el archivo y esperá a que el kubelet reinicie el Pod estático:

   ```bash
   sudo crictl ps | grep kube-apiserver
   kubectl -n kube-system get pod -l component=kube-apiserver
   until kubectl get --raw='/readyz' 2>/dev/null; do sleep 3; done; echo
   ```

5. Creá un Secret **nuevo** y leelo desde etcd:

   ```bash
   kubectl -n secret-lab create secret generic post-enc --from-literal=token=after-encryption

   sudo ETCDCTL_API=3 etcdctl \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     --endpoints=https://127.0.0.1:2379 \
     get /registry/secrets/secret-lab/post-enc | hexdump -C | head -n 5
   ```

6. Ahora releé el Secret creado **antes** de habilitar el cifrado:

   ```bash
   sudo ETCDCTL_API=3 etcdctl \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     --endpoints=https://127.0.0.1:2379 \
     get /registry/secrets/secret-lab/app-db | hexdump -C | head -n 5
   ```

7. Forzá a cada Secret existente a pasar por la ruta de escritura para que quede cifrado:

   ```bash
   kubectl get secrets --all-namespaces -o json | kubectl replace -f -
   ```

   Verificá `app-db` otra vez con el comando del paso 6.

8. Confirmá que el clúster sigue funcionando desde el lado del cliente:

   ```bash
   kubectl -n secret-lab get secret app-db -o jsonpath='{.data.password}' | base64 -d; echo
   ```

### Verificá tu comprensión

- **P2.1** ¿Qué prefijo apareció delante del payload cifrado en el paso 5, y cuáles son sus componentes?
- **P2.2** ¿Por qué `identity: {}` se lista **después** de `secretbox` y no antes? ¿Qué se rompe si lo ponés primero?
- **P2.3** El paso 6 mostró texto plano. Explicá con precisión por qué, y qué hace el paso 7 al respecto.
- **P2.4** En el paso 8 seguiste leyendo la contraseña con `kubectl`. ¿Qué amenaza mitiga realmente el cifrado en reposo, y cuál *no*?
- **P2.5** Agregaste `--encryption-provider-config-automatic-reload=true`. ¿Qué cambio podés hacer ahora sin reiniciar el API server, y qué cambio sigue requiriendo uno?
- **P2.6** La documentación de Kubernetes marca `aescbc` como no recomendado y trata a KMS v2 como el proveedor preferido. Dá una razón para cada una de esas posiciones.
- **P2.7** Para revertir el cifrado de manera segura, ¿cuál es el orden exacto de las operaciones?

---

## Ejercicio 3 — Consumir Secrets desde un Pod: variables de entorno vs archivos proyectados

### Pasos

1. Desplegá un Pod que consuma el Secret como variables de entorno:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: env-consumer
     namespace: secret-lab
   spec:
     containers:
       - name: app
         image: busybox:1.36
         command: ["sh", "-c", "sleep 3600"]
         envFrom:
           - secretRef:
               name: app-db
   EOF
   kubectl -n secret-lab wait --for=condition=Ready pod/env-consumer --timeout=60s
   ```

2. Enumerá la superficie de fuga del enfoque por variables de entorno:

   ```bash
   kubectl -n secret-lab exec env-consumer -- env | grep -E 'username|password'
   kubectl -n secret-lab exec env-consumer -- cat /proc/1/environ | tr '\0' '\n' | grep password
   ```

3. Rotá el valor del Secret y verificá si el contenedor en ejecución ve el cambio:

   ```bash
   kubectl -n secret-lab patch secret app-db \
     -p '{"stringData":{"password":"R0tated-P@ss"}}'
   sleep 10
   kubectl -n secret-lab exec env-consumer -- env | grep password
   ```

4. Desplegá un Pod que monte el mismo Secret como un volumen de solo lectura con permisos restrictivos:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: file-consumer
     namespace: secret-lab
   spec:
     automountServiceAccountToken: false
     securityContext:
       runAsNonRoot: true
       runAsUser: 10001
       fsGroup: 10001
     containers:
       - name: app
         image: busybox:1.36
         command: ["sh", "-c", "sleep 3600"]
         securityContext:
           allowPrivilegeEscalation: false
           readOnlyRootFilesystem: true
           capabilities:
             drop: ["ALL"]
         volumeMounts:
           - name: db
             mountPath: /etc/db
             readOnly: true
     volumes:
       - name: db
         secret:
           secretName: app-db
           defaultMode: 0400
           items:
             - key: password
               path: password
   EOF
   kubectl -n secret-lab wait --for=condition=Ready pod/file-consumer --timeout=60s
   ```

5. Inspeccioná qué aterrizó en el contenedor:

   ```bash
   kubectl -n secret-lab exec file-consumer -- ls -l /etc/db/
   kubectl -n secret-lab exec file-consumer -- ls -l /etc/db/..data/
   kubectl -n secret-lab exec file-consumer -- cat /etc/db/password; echo
   kubectl -n secret-lab exec file-consumer -- ls -a /etc/db/
   ```

6. Rotá otra vez y observá la propagación al archivo montado:

   ```bash
   kubectl -n secret-lab patch secret app-db \
     -p '{"stringData":{"password":"R0tated-Twice"}}'
   for i in $(seq 1 12); do
     kubectl -n secret-lab exec file-consumer -- cat /etc/db/password; echo
     sleep 10
   done
   ```

7. Hacé el Secret inmutable e intentá cambiarlo:

   ```bash
   kubectl -n secret-lab patch secret app-api -p '{"immutable":true}'
   kubectl -n secret-lab patch secret app-api -p '{"stringData":{"apikey":"ak-new"}}'
   ```

### Verificá tu comprensión

- **P3.1** Enumerá tres maneras distintas en que el valor expuesto en el paso 2 puede escapar del contenedor y que **no** aplican a un Secret montado como archivo.
- **P3.2** Paso 3 vs paso 6: ¿qué método de consumo captó la rotación, y cuál es el mecanismo detrás de la diferencia?
- **P3.3** ¿Qué son `..data` y `..2026_07_29_...` en el directorio de montaje, y por qué ese diseño importa para la rotación atómica?
- **P3.4** ¿Qué campo único del manifiesto de `file-consumer` rompería el comportamiento de auto-actualización si lo usaras para montar una sola clave dentro de un directorio existente?
- **P3.5** ¿Por qué `automountServiceAccountToken: false` es un control de gestión de Secrets y no solo una prolijidad?
- **P3.6** El paso 7 falló. Nombrá dos beneficios de `immutable: true` — uno relacionado con la seguridad, otro con el rendimiento — y explicá cómo rotarías entonces el valor.
- **P3.7** Se solicitó `defaultMode: 0400`. ¿Por qué el modo efectivo puede diferir igual de lo que esperás, y qué campo interactúa con él?

---

## Ejercicio 4 — RBAC de mínimo privilegio para Secrets

### Pasos

1. Creá un ServiceAccount y un Role que otorgue acceso a exactamente un Secret:

   ```bash
   kubectl -n secret-lab create serviceaccount app-sa

   cat <<'EOF' | kubectl apply -f -
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: read-app-db
     namespace: secret-lab
   rules:
     - apiGroups: [""]
       resources: ["secrets"]
       resourceNames: ["app-db"]
       verbs: ["get"]
   EOF

   kubectl -n secret-lab create rolebinding app-sa-read-app-db \
     --role=read-app-db --serviceaccount=secret-lab:app-sa
   ```

2. Probá el límite de permisos con impersonación:

   ```bash
   SA=system:serviceaccount:secret-lab:app-sa
   kubectl auth can-i get secret/app-db      -n secret-lab --as=$SA
   kubectl auth can-i get secret/app-api     -n secret-lab --as=$SA
   kubectl auth can-i list secrets           -n secret-lab --as=$SA
   kubectl auth can-i get secrets            -n secret-lab --as=$SA -n kube-system
   ```

3. Confirmá el comportamiento con una petición real en lugar de una comprobación en seco:

   ```bash
   kubectl -n secret-lab get secret app-db  --as=$SA -o jsonpath='{.data.username}' | base64 -d; echo
   kubectl -n secret-lab get secret app-api --as=$SA
   kubectl -n secret-lab get secrets        --as=$SA
   ```

4. Ahora agregá una regla de `list` y observá qué puede y qué no puede hacer `resourceNames`:

   ```bash
   kubectl -n secret-lab patch role read-app-db --type=json -p \
     '[{"op":"add","path":"/rules/0/verbs/-","value":"list"}]'
   kubectl -n secret-lab get secrets --as=$SA
   ```

5. Quitá de nuevo el verbo `list` y después sondeá la ruta de escalación clásica:

   ```bash
   kubectl -n secret-lab patch role read-app-db --type=json -p \
     '[{"op":"remove","path":"/rules/0/verbs/1"}]'

   kubectl auth can-i create pods -n secret-lab --as=$SA
   ```

6. Auditá el clúster en busca de accesos demasiado amplios a Secrets:

   ```bash
   kubectl get clusterroles -o json | jq -r '
     .items[] | select(.rules[]? |
       ((.resources//[]) | index("secrets") or index("*")) and
       ((.verbs//[]) | index("get") or index("list") or index("*"))
     ) | .metadata.name' | sort -u

   kubectl get clusterrolebindings -o json | jq -r '
     .items[] | select(.roleRef.name=="cluster-admin") |
     "\(.metadata.name): \([.subjects[]?|"\(.kind)/\(.name)"]|join(","))"'
   ```

### Verificá tu comprensión

- **P4.1** El paso 2 mostró `get secret/app-db` permitido pero `list secrets` denegado incluso después de que el Role cubriera `secrets`. ¿Por qué `resourceNames` no restringe `list` ni `watch` de una manera útil?
- **P4.2** En el paso 4, una vez otorgado `list`, ¿qué recibió realmente `app-sa`? ¿Por qué es una decisión de autorización que la gente equivoca con frecuencia?
- **P4.3** El paso 5 verificó `create pods`. Explicá por qué la respuesta a esa pregunta puede volver irrelevante todo el Role del paso 1.
- **P4.4** Dá dos mitigaciones para la ruta de escalación de P4.3 que no impliquen cambiar este Role.
- **P4.5** ¿Por qué `kubectl auth can-i --as` es evidencia aceptable en una revisión de hardening, y qué es una cosa que no te va a decir?
- **P4.6** ¿Qué ClusterRoles integrados aparecen típicamente en la salida del paso 6 por razones legítimas, y cómo triarías la lista?

---

## Ejercicio 5 — Tokens de service account acotados y credenciales de vida corta

### Pasos

1. Inspeccioná el token que el API server proyecta por defecto dentro de un Pod:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: token-inspect
     namespace: secret-lab
   spec:
     serviceAccountName: app-sa
     containers:
       - name: app
         image: busybox:1.36
         command: ["sh", "-c", "sleep 3600"]
   EOF
   kubectl -n secret-lab wait --for=condition=Ready pod/token-inspect --timeout=60s

   kubectl -n secret-lab exec token-inspect -- ls /var/run/secrets/kubernetes.io/serviceaccount/
   ```

2. Decodificá el payload del token:

   ```bash
   kubectl -n secret-lab exec token-inspect -- \
     cat /var/run/secrets/kubernetes.io/serviceaccount/token \
     | cut -d. -f2 | base64 -d 2>/dev/null | jq .
   ```

3. Verificá si un Secret de larga duración respalda este ServiceAccount:

   ```bash
   kubectl -n secret-lab get serviceaccount app-sa -o yaml
   kubectl -n secret-lab get secrets
   ```

4. Solicitá un token explícitamente acotado a la API TokenRequest:

   ```bash
   kubectl -n secret-lab create token app-sa --duration=10m --audience=vault \
     | cut -d. -f2 | base64 -d 2>/dev/null | jq '{aud, exp, iat, sub}'
   ```

5. Proyectá dentro de un Pod un token de vida corta con audiencia personalizada:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: token-projected
     namespace: secret-lab
   spec:
     serviceAccountName: app-sa
     automountServiceAccountToken: false
     containers:
       - name: app
         image: busybox:1.36
         command: ["sh", "-c", "sleep 3600"]
         volumeMounts:
           - name: vault-token
             mountPath: /var/run/secrets/tokens
             readOnly: true
     volumes:
       - name: vault-token
         projected:
           sources:
             - serviceAccountToken:
                 path: vault-token
                 audience: vault
                 expirationSeconds: 600
   EOF
   kubectl -n secret-lab wait --for=condition=Ready pod/token-projected --timeout=60s

   kubectl -n secret-lab exec token-projected -- \
     cat /var/run/secrets/tokens/vault-token \
     | cut -d. -f2 | base64 -d 2>/dev/null | jq '{aud, exp, "kubernetes.io"}'
   ```

6. Creá un Secret de token heredado, sin expiración, y compará:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Secret
   metadata:
     name: app-sa-legacy-token
     namespace: secret-lab
     annotations:
       kubernetes.io/service-account.name: app-sa
   type: kubernetes.io/service-account-token
   EOF

   kubectl -n secret-lab get secret app-sa-legacy-token \
     -o jsonpath='{.data.token}' | base64 -d | cut -d. -f2 | base64 -d 2>/dev/null | jq .
   ```

7. Verificá que una audiencia que no coincide sea rechazada:

   ```bash
   TOKEN=$(kubectl -n secret-lab create token app-sa --audience=vault)
   cat <<EOF | kubectl create -o json -f - | jq '.status'
   apiVersion: authentication.k8s.io/v1
   kind: TokenReview
   spec:
     token: "${TOKEN}"
     audiences: ["https://kubernetes.default.svc"]
   EOF
   ```

### Verificá tu comprensión

- **P5.1** ¿Qué claims del paso 2 prueban que el token está *acotado*, y acotado a qué exactamente?
- **P5.2** El paso 3 no encontró ningún Secret de token autogenerado para `app-sa`. ¿Qué cambió en Kubernetes para que eso sea la norma, y por qué es una mejora de seguridad?
- **P5.3** Compará los payloads del paso 5 y el paso 6. ¿Cuál es la diferencia práctica de radio de impacto si cada token se filtra?
- **P5.4** ¿Por qué importa el campo `audience` cuando una carga de trabajo se autentica ante un sistema externo como Vault?
- **P5.5** En el paso 5 se combinó `automountServiceAccountToken: false` con un token proyectado. ¿Es contradictorio? Explicá.
- **P5.6** El paso 7 devolvió un resultado no autenticado. ¿Qué componente realiza esta verificación en una integración real, y qué ataque detiene?

---

## Ejercicio 6 — Mantener los Secrets fuera del log de auditoría y fuera de los manifiestos

### Pasos

1. Escribí una política de auditoría que registre el acceso a Secrets sin registrar su contenido:

   ```bash
   sudo mkdir -p /etc/kubernetes/audit
   sudo tee /etc/kubernetes/audit/policy.yaml >/dev/null <<'EOF'
   apiVersion: audit.k8s.io/v1
   kind: Policy
   omitStages:
     - RequestReceived
   rules:
     - level: Metadata
       resources:
         - group: ""
           resources: ["secrets", "configmaps"]
     - level: Metadata
       resources:
         - group: "authentication.k8s.io"
           resources: ["tokenreviews"]
     - level: RequestResponse
       resources:
         - group: "rbac.authorization.k8s.io"
           resources: ["roles", "clusterroles", "rolebindings", "clusterrolebindings"]
     - level: Metadata
   EOF
   ```

2. Habilitala en el API server (`/etc/kubernetes/manifests/kube-apiserver.yaml`), reutilizando la costumbre de backup del Ejercicio 2:

   ```yaml
       - --audit-policy-file=/etc/kubernetes/audit/policy.yaml
       - --audit-log-path=/var/log/kubernetes/audit/audit.log
       - --audit-log-maxage=30
       - --audit-log-maxbackup=5
       - --audit-log-maxsize=100
   ```

   Montá tanto el directorio de la política (solo lectura) como el directorio de logs (escribible), y después esperá a que esté listo como en el paso 4 del Ejercicio 2.

3. Generá tráfico de Secrets e inspeccioná qué quedó registrado:

   ```bash
   kubectl -n secret-lab get secret app-db -o yaml >/dev/null
   sudo grep '"resource":"secrets"' /var/log/kubernetes/audit/audit.log | tail -n 1 | jq .
   ```

4. Confirmá que el valor está ausente del log:

   ```bash
   sudo grep -c 'R0tated-Twice' /var/log/kubernetes/audit/audit.log || echo "value not present"
   ```

5. Detectá material de Secrets commiteado dentro de manifiestos, la fuga más común en el mundo real:

   ```bash
   kubectl -n secret-lab set env deployment/dummy FOO=bar --dry-run=client 2>/dev/null || true

   cat <<'EOF' > /tmp/bad-pod.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: hardcoded
     namespace: secret-lab
   spec:
     containers:
       - name: app
         image: busybox:1.36
         env:
           - name: DB_PASSWORD
             value: "S3cr3t-P@ss"
   EOF

   grep -nEi '(password|passwd|secret|token|apikey|api_key)[[:space:]]*:' /tmp/bad-pod.yaml
   ```

6. Refactorizá el manifiesto para que referencie un Secret en lugar de embeber el valor, y verificá que la carga de trabajo siga arrancando:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: hardcoded-fixed
     namespace: secret-lab
   spec:
     automountServiceAccountToken: false
     containers:
       - name: app
         image: busybox:1.36
         command: ["sh", "-c", "sleep 3600"]
         volumeMounts:
           - name: db
             mountPath: /etc/db
             readOnly: true
     volumes:
       - name: db
         secret:
           secretName: app-db
           defaultMode: 0400
   EOF
   kubectl -n secret-lab wait --for=condition=Ready pod/hardcoded-fixed --timeout=60s
   ```

7. Bosquejá el patrón de almacén externo y razoná sobre él sin instalar un proveedor:

   ```bash
   cat <<'EOF' > /tmp/spc.yaml
   apiVersion: secrets-store.csi.x-k8s.io/v1
   kind: SecretProviderClass
   metadata:
     name: vault-db
     namespace: secret-lab
   spec:
     provider: vault
     parameters:
       roleName: app-role
       vaultAddress: https://vault.example.internal:8200
       objects: |
         - objectName: "password"
           secretPath: "secret/data/app/db"
           secretKey: "password"
   EOF

   kubectl apply -f /tmp/spc.yaml --dry-run=client -o yaml | head -n 8
   ```

### Verificá tu comprensión

- **P6.1** ¿Por qué `level: Metadata` es obligatorio para `secrets` en lugar de `Request` o `RequestResponse`?
- **P6.2** El orden de las reglas importa en una política de auditoría. ¿Qué pasaría si la regla comodín `level: Metadata` se moviera al principio?
- **P6.3** El log de auditoría registra un `get` sobre un Secret. ¿Registra que un Pod leyó un archivo de Secret montado? ¿Por qué es eso una brecha de monitoreo, y qué correlacionarías en su lugar?
- **P6.4** Más allá del historial de git, nombrá otros dos lugares donde suele terminar un valor hardcodeado del paso 5.
- **P6.5** En el patrón CSI del paso 7, ¿dónde vive el material del Secret en reposo, y qué exposición local del Ejercicio 1 elimina eso?
- **P6.6** `secretObjects` / `syncSecret` pueden replicar un secreto externo dentro de un Secret de Kubernetes. ¿Qué ganás y qué resignás al habilitar eso?
- **P6.7** Tenés cifrado en reposo, RBAC estricto, montajes basados en archivos y un almacén externo. Ordená estos cuatro según cuánto riesgo residual elimina cada uno, y justificá la primera opción.

---

## Limpieza

```bash
kubectl delete namespace secret-lab

# Roll back the API server changes if this was a scratch cluster
sudo cp /root/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml
until kubectl get --raw='/readyz' 2>/dev/null; do sleep 3; done; echo
```

> Si mantenés el cifrado habilitado pero borrás el archivo de claves, cada Secret cifrado queda ilegible. Tratá a `/etc/kubernetes/enc/enc.yaml` como un artefacto crítico para el backup, y nunca lo guardes dentro del clúster que protege.

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1

**R1.1** Sí — la contraseña aparece en la salida de etcd como ASCII legible dentro del objeto serializado. Por defecto los Secrets de Kubernetes se almacenan en etcd **sin cifrar**; la única diferencia con un ConfigMap es la codificación base64 de los valores, un tipo de recurso distinto a efectos de RBAC, y el hecho de que no se escriben en el disco del nodo en el caso habitual (el kubelet los mantiene en tmpfs). Cualquiera con acceso a los archivos de etcd, un certificado de cliente de etcd, o un snapshot de backup de etcd los lee en claro.

**R1.2** base64 es una codificación reversible sin clave. Existe para que los valores binarios puedan embeberse en JSON/YAML. Cualquiera que tenga la cadena codificada tiene el secreto.

**R1.3** Ambas necesitan `get` sobre `secrets`. `describe` simplemente elige no imprimir los valores del lado del cliente — la respuesta de la API los contenía de todos modos. No existe un permiso de lectura que devuelva los metadatos de un Secret y oculte sus datos, así que "dejalos describir el Secret" no es un privilegio menor que "dejalos leerlo".

**R1.4** `stringData` es de solo escritura: el API server lo codifica en base64 dentro de `data` y el objeto almacenado muestra solo `data`. Si una clave aparece en ambos, gana el valor de `stringData`.

**R1.5** `echo` agrega un salto de línea, así que `--from-file` sobre un archivo así almacena `S3cr3t-P@ss\n`. La aplicación entonces se autentica con un salto de línea final y falla, o el operador agrega un workaround con `tr -d '\n'`. Usá `echo -n`, `printf`, o `--from-literal`.

### Ejercicio 2

**R2.1** `k8s:enc:secretbox:v1:key1:` seguido del texto cifrado. Componentes: el marcador `k8s:enc:`, el nombre del proveedor (`secretbox`), la versión interna del proveedor, y el **nombre de la clave** tomado de la configuración — que es como el API server sabe qué clave usar para descifrar.

**R2.2** El **primer** proveedor de la lista se usa para las **escrituras**; todos los proveedores listados se prueban para las **lecturas**. `identity` significa "sin cifrado". Ponerlo primero haría que cada escritura volviera a ser texto plano, aun descifrando correctamente los datos viejos — cifrado silenciosamente deshabilitado y sin ningún error.

**R2.3** El cifrado ocurre en la escritura. Los objetos que ya están en etcd quedan intactos hasta que algo los reescribe. El paso 7 lee cada Secret y le hace `replace`, forzando una escritura a través del nuevo proveedor para que se reserialice cifrado. Tenés que repetir esto después de cualquier rotación de claves que retire la clave vieja.

**R2.4** Mitiga el acceso **offline** al almacén de datos: volúmenes de etcd robados, snapshots de backup de etcd, acceso directo con un cliente de etcd, y forense de disco. **No** protege contra nadie autorizado a través del API server — RBAC sigue siendo tu único control ahí — ni contra un API server comprometido, que tiene la clave.

**R2.5** Con la recarga automática podés agregar una clave nueva, reordenar claves, o cambiar qué recursos están cubiertos editando `enc.yaml` — el API server lo toma sin reiniciar (una métrica de salud/recarga refleja el resultado). Agregar o quitar el propio flag `--encryption-provider-config`, o el volume mount, sigue requiriendo que el Pod estático se reinicie.

**R2.6** `aescbc` usa el modo CBC sin autenticar el texto cifrado, lo que lo expone a ataques del estilo padding-oracle; `secretbox` y AES-GCM son autenticados. KMS v2 es preferido porque las claves de cifrado de datos van envueltas por un KMS externo, de modo que la clave raíz nunca queda en un archivo del nodo del plano de control, y soporta rotación y DEKs por objeto con muchísimo menos riesgo operativo.

**R2.7** (1) Editar `enc.yaml` para que `identity: {}` pase a ser el primer proveedor manteniendo la clave vieja listada después; (2) dejar que la configuración se recargue (o reiniciar el API server); (3) reescribir todos los Secrets con `kubectl get secrets -A -o json | kubectl replace -f -` para que queden almacenados en texto plano; (4) recién entonces quitar el material de claves y el flag. Quitar la clave antes del paso 3 vuelve los Secrets existentes permanentemente ilegibles.

### Ejercicio 3

**R3.1** Cualquiera de estas: el entorno completo es legible vía `/proc/<pid>/environ` por cualquier proceso del contenedor (y por cualquier cosa que comparta el namespace de PID); el entorno lo hereda cada proceso hijo, incluidos shells de depuración y manejadores de fallos; los volcados de fallos, `docker inspect`/`crictl inspect`, y muchos frameworks de aplicación o rastreadores de errores vuelcan el entorno en los logs; `kubectl exec ... env` no requiere ningún RBAC sobre Secrets, solo `pods/exec`. A los archivos, además, se les puede dar modos restrictivos y montarlos en solo lectura, cosa que las variables de entorno no permiten.

**R3.2** Solo el **volume mount** captó el valor nuevo. Las variables de entorno se resuelven una vez al arrancar el contenedor y son inmutables durante la vida del proceso — hay que recrear el Pod. Los Secrets montados los refresca el kubelet en su bucle de sincronización (hasta aproximadamente el período de sync del kubelet más el TTL de caché, típicamente dentro de uno o dos minutos), y el intercambio del symlink hace visible la actualización sin reiniciar.

**R3.3** El kubelet escribe cada versión del Secret en un directorio oculto con marca temporal (`..2026_07_29_10_11_12.123456789`), apunta el symlink `..data` hacia él, y expone cada clave como un symlink dentro de `..data`. Actualizar significa crear un nuevo directorio con marca temporal y reapuntar atómicamente `..data`, de modo que un lector nunca observa un conjunto de claves escrito a medias — todas las claves cambian juntas o no cambia ninguna.

**R3.4** `subPath`. Un montaje con `subPath` se resuelve una vez al arrancar el contenedor y el kubelet **nunca** lo actualiza, lo que anula silenciosamente la rotación de Secrets. Usá en cambio un directorio de montaje dedicado más `items`.

**R3.5** El token proyectado de la service account es una credencial para la propia API de Kubernetes. Dejado montado en una carga de trabajo que nunca llama a la API, es material gratuito de movimiento lateral para cualquiera que logre ejecución de código en ese contenedor. Deshabilitarlo elimina un Secret que no hacía falta repartir — configuralo en el ServiceAccount o en el Pod, y volvé a habilitarlo explícitamente por carga de trabajo.

**R3.6** Seguridad: nada puede modificar el Secret en el lugar, así que un atacante con `patch`/`update` sobre Secrets no puede intercambiar credenciales por debajo de una carga de trabajo en ejecución, y la rotación se vuelve un crear-y-redesplegar explícito y auditable. Rendimiento: el kubelet deja de observar ese Secret en busca de cambios, lo que reduce materialmente la carga del API server en clústeres grandes. Para rotar el valor tenés que borrar el Secret y crearlo de nuevo (y después reiniciar a los consumidores), o crear un nombre de Secret nuevo versionado y actualizar la carga de trabajo para que lo referencie — este último es el patrón más seguro.

**R3.7** `defaultMode` está sujeto a la semántica del umask del contenedor solo indirectamente; más importante aún, interactúa con `fsGroup` y con `runAsUser` — los archivos pertenecen a root con el GID de `fsGroup`, así que un usuario no root los lee por pertenencia al grupo. Con `0400` y sin el bit de grupo correspondiente, el proceso puede quedar sin poder leer su propio Secret; `0440` más `fsGroup` es la combinación que normalmente funciona. El `items[].mode` por clave sobrescribe a `defaultMode`.

### Ejercicio 4

**R4.1** `resourceNames` filtra por el nombre del objeto tomado de la ruta de la petición. Las peticiones `list` y `watch` se hacen contra la **colección** (`/api/v1/namespaces/secret-lab/secrets`) y no llevan nombre de objeto, así que una regla con `resourceNames` no puede coincidir con ellas — la petición simplemente se deniega. No existe una manera soportada de decir "listar solo estos Secrets" en RBAC; los selectores de campo/etiqueta no son límites de autorización.

**R4.2** Recibió la capacidad de listar **todos** los Secrets del namespace, incluidos sus datos — `resourceNames` no lo acotó. La gente asume que `resourceNames` limita todos los verbos de la regla; en la práctica, otorgar `list` sobre `secrets` en un namespace equivale a otorgar lectura sobre todos los Secrets de ese namespace.

**R4.3** Cualquiera que pueda crear Pods en un namespace puede montar **cualquier** Secret de ese namespace dentro de un contenedor que controla y leerlo — el kubelet, no quien hace la petición, realiza la lectura. Así que `create pods` en `secret-lab` es un superconjunto del acceso de lectura a todos los Secrets de `secret-lab`, lo que vuelve cosmético el Role cuidadosamente acotado. Lo mismo aplica a los controladores que crean Pods en nombre del usuario.

**R4.4** Las opciones incluyen: mantener los Secrets en namespaces donde principales no confiables no puedan crear Pods (aislamiento por namespace como el límite real); usar una política de admisión (ValidatingAdmissionPolicy, Kyverno, Gatekeeper) que restrinja qué Secrets puede referenciar un Pod; obtener la credencial desde un almacén externo con identidad por carga de trabajo, de modo que una spec de Pod por sí sola no alcance; exigir que la identidad de la carga de trabajo se autentique ante el almacén con un token acotado y con audiencia específica.

**R4.5** `auth can-i --as` le hace al autorizador del API server la misma pregunta que haría una petición real, así que refleja la unión efectiva de todos los bindings — mejor evidencia que leer los Roles a mano. No te va a hablar de rutas indirectas (creación de Pods, controladores, impersonación, escalación vía `bind`/`escalate`), ni de nada que se aplique en admisión en lugar de en autorización, y requiere privilegios de impersonación para ejecutarse.

**R4.6** Van a aparecer `cluster-admin`, `system:kube-controller-manager`, `system:controller:*` (muchos controladores leen Secrets legítimamente), y roles del estilo `system:kubelet-...`. Triá preguntando: ¿es este un rol agregado/de sistema que trae Kubernetes, y los bindings están limitados a identidades de sistema? Después enfocate en ClusterRoles personalizados con `secrets` + `get/list/*`, comodines (`resources: ["*"]`), y cualquier ClusterRoleBinding que coloque usuarios humanos o un grupo amplio como `system:authenticated` dentro de ellos.

### Ejercicio 5

**R5.1** El claim `kubernetes.io` contiene el `namespace`, la `serviceaccount` (nombre y UID), **y** el `pod` (nombre y UID) — esa vinculación al pod es lo que lo convierte en un token acotado. También lleva `exp` (una expiración corta, una hora por defecto, refrescada automáticamente por el kubelet) y `aud` fijado al identificador del API server. Si el Pod se borra, el token deja de ser válido incluso antes de `exp`.

**R5.2** Kubernetes dejó de crear automáticamente Secrets de token permanentes para las ServiceAccounts; ahora el kubelet obtiene los tokens a través de la API TokenRequest y los proyecta dentro del Pod. La mejora es que las credenciales son de vida corta, están acotadas a un Pod específico, tienen audiencia definida, y nunca se persisten como un objeto del clúster que un atacante pueda listar y reutilizar indefinidamente.

**R5.3** El token proyectado expira en 600 segundos, solo lo acepta una audiencia `vault`, y muere con el Pod — una filtración es una ventana angosta y acotada en el tiempo contra un solo sistema. El Secret de token heredado **no** tiene `exp`, tiene una audiencia general y ninguna vinculación al pod: es una credencial permanente del clúster para esa ServiceAccount, reutilizable desde cualquier lado hasta que se borre el Secret, y es a su vez un Secret sentado en etcd.

**R5.4** La vinculación por audiencia impide que un token emitido para una parte confiante se replique contra otra. Sin ella, un token entregado a Vault podría darse vuelta y usarse directamente contra la API de Kubernetes (o contra un segundo servicio externo) por quien lo reciba — un problema de diputado confundido. Con `aud: vault`, el API server lo rechaza para cualquier otra audiencia.

**R5.5** No es contradictorio — es la combinación recomendada. `automountServiceAccountToken: false` suprime el token de API general de *por defecto* en `/var/run/secrets/kubernetes.io/serviceaccount`, mientras que el volumen proyectado provee exactamente un token con una audiencia y un tiempo de vida acotados, en una ruta que elegiste vos. La carga de trabajo obtiene la credencial que necesita y nada más.

**R5.6** La parte confiante (Vault, o cualquier servicio que se integre con la autenticación de Kubernetes) llama a `TokenReview` con las audiencias que espera; la capa de autenticación del API server realiza la validación. Detiene la reutilización de tokens entre audiencias, y también atrapa tokens expirados, revocados por borrado del pod, y falsificados.

### Ejercicio 6

**R6.1** En el nivel `Request` o `RequestResponse` el backend de auditoría escribe el cuerpo del objeto en el log — para un Secret eso significa que los valores codificados en base64 aterrizan en un archivo de log en texto plano, normalmente con acceso de lectura más amplio y retención más larga que etcd, y a menudo enviado fuera del clúster a un agregador de logs. `Metadata` registra quién hizo qué, sobre qué objeto, cuándo y desde dónde, sin el payload. (El API server trata algunos de estos casos de manera especial, pero apoyarse en eso en vez de escribir la regla correctamente es un hallazgo.)

**R6.2** Las reglas de auditoría se evalúan de arriba hacia abajo y **gana la primera coincidencia**. Una regla comodín `Metadata` al principio se tragaría cada petición, así que la regla `RequestResponse` específica de RBAC nunca se dispararía y perderías el registro detallado de los cambios de permisos. Ordená las reglas específicas antes que las generales.

**R6.3** No. Una vez que un Secret está montado, las lecturas ocurren dentro del contenedor contra un archivo en tmpfs y nunca tocan el API server, así que no hay evento de auditoría. El log de auditoría muestra el acceso al Secret por parte del kubelet/API server en el momento de la admisión del Pod, no el uso por lectura. Para razonar sobre quién accedió a qué, correlacionás el rastro de auditoría del Secret con los eventos de creación de Pods (qué Pod referenció qué Secret, creado por qué principal) y con herramientas de runtime como Falco observando las aperturas bajo la ruta de montaje.

**R6.4** Los habituales: logs de jobs de CI/CD y artefactos de build; el propio clúster, donde el valor es visible en `kubectl get pod -o yaml` para cualquiera con `get pods` (un permiso mucho más ampliamente otorgado que `get secrets`); el historial del repositorio GitOps y los manifiestos de Helm renderizados; las imágenes de contenedor si el manifiesto queda horneado adentro; sistemas de tickets y chats donde se pegan manifiestos.

**R6.5** El material vive en el almacén externo (Vault, un gestor de secretos en la nube, un KMS respaldado por HSM), y el driver CSI lo entrega en el montaje tmpfs del Pod al arrancar. Esto elimina por completo la exposición en etcd — no hay objeto Secret de Kubernetes que leer desde etcd, desde un backup de etcd, o vía RBAC de `get secrets`.

**R6.6** Ganás compatibilidad: las cargas de trabajo que necesitan `envFrom`/`secretKeyRef`, y los controladores que esperan un objeto Secret (TLS de ingress, secrets de pull de imágenes), siguen funcionando. Resignás el beneficio principal — el valor ahora se escribe de nuevo en etcd, sujeto al RBAC de Secrets y a cualquier cifrado en reposo que hayas configurado, y se vuelve una segunda copia que puede desviarse de la fuente de verdad. Habilitalo solo donde un consumidor real requiera un objeto Secret.

**R6.7** Un ordenamiento defendible: (1) **RBAC estricto / aislamiento por namespace**, porque la ruta del llamante autorizado de la API es la que los atacantes realmente usan, y es el único control que limita quién puede leer un Secret en absoluto — incluida la escalación vía creación de Pods; (2) **almacén externo con identidad de carga de trabajo**, que reduce lo que existe en el clúster a material de vida corta y por carga de trabajo; (3) **montajes basados en archivos con modos restrictivos y sin `subPath`**, que reduce la exposición dentro del contenedor y habilita la rotación; (4) **cifrado en reposo**, que es necesario y a menudo obligatorio pero solo aborda el compromiso offline del almacén de datos mientras el API server tiene la clave. La primera opción es RBAC porque las otras tres asumen un atacante que todavía no obtuvo acceso legítimo a la API — RBAC es lo que decide eso.

</details>

---

## Referencias

- CNCF CKS Curriculum v1.34 — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubernetes — Secrets — https://kubernetes.io/docs/concepts/configuration/secret/
- Kubernetes — Encrypting Confidential Data at Rest — https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
- Kubernetes — Using a KMS provider for data encryption — https://kubernetes.io/docs/tasks/administer-cluster/kms-provider/
- Kubernetes — Good practices for Kubernetes Secrets — https://kubernetes.io/docs/concepts/security/secrets-good-practices/
- Kubernetes — Distribute Credentials Securely Using Secrets — https://kubernetes.io/docs/tasks/inject-data-application/distribute-credentials-secure/
- Kubernetes — Projected Volumes — https://kubernetes.io/docs/concepts/storage/projected-volumes/
- Kubernetes — Managing Service Accounts / Bound tokens — https://kubernetes.io/docs/concepts/security/service-accounts/
- Kubernetes — Using RBAC Authorization — https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Kubernetes — Auditing — https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Kubernetes Secrets Store CSI Driver — https://secrets-store-csi-driver.sigs.k8s.io/