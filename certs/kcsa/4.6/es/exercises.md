# Guía de Estudio KCSA: Tema 4.6 – Acceso a Datos Sensibles

**Examen:** CNCF Kubernetes and Cloud Native Security Associate (KCSA)  
**Dominio 4:** Seguridad de Aplicaciones  
**Subtema 4.6:** Acceso a Datos Sensibles  
**Peso del Dominio:** 2.29%  
**Autor:** Principal Platform Architect & Senior SRE Instructor  

---

## 1. Esquema Arquitectónico y Mecánica Técnica Profunda

### 1.1 La Superficie de Ataque de los Datos Sensibles en Kubernetes
En arquitecturas cloud-native, los "datos sensibles" abarcan credenciales de bases de datos, claves privadas TLS, tokens de API, claves de cifrado y tokens de SaaS de terceros. Acceder y gestionar datos sensibles introduce múltiples vectores de ataque a lo largo del stack de Kubernetes:

```
                      +-------------------------------------------------+
                      |            API Server Security Boundary         |
                      +-------------------------------------------------+
                                       |                |
                    RBAC / Audit       |                | Storage Layer
                    Inspection         v                v
            +-----------------------+     +-------------------------------+
            |  Secret Enumeration   |     |  etcd Storage (Unencrypted)   |
            |  & RBAC Misconfig     |     |  Base64 != Encryption         |
            +-----------------------+     +-------------------------------+
                       |                                |
                       v                                v
            +-----------------------+     +-------------------------------+
            | Compromised Service   |     | Physical / Snapshot Theft     |
            | Account / API Token   |     | of etcd Datastore             |
            +-----------------------+     +-------------------------------+
                       |
                       +--------------------------------+
                       |                                |
  Pod Execution        v                                v
  Memory & Env  +-----------------------+     +-------------------------------+
                | Env Var Leakage via   |     | Memory Dumping / Proc FS      |
                | /proc/$PID/environ    |     | Unencrypted Disk Swapping     |
                +-----------------------+     +-------------------------------+
```

### 1.2 Espectro de Defensa en Profundidad para Kubernetes Secrets

1. **Capa de Almacenamiento (Cifrado en Reposo / At-Rest Encryption):**
   - **Estado por Defecto:** Los Kubernetes Secrets se almacenan en `etcd` como cadenas codificadas en Base64 (`serializers/json`). Base64 es un formato de codificación, **no** cifrado. Cualquier entidad con acceso a los backups de `etcd` o a la memoria del host puede extraer todos los secrets del cluster.
   - **`EncryptionConfiguration`:** Configura el `kube-apiserver` para cifrar los recursos de tipo secret antes de escribirlos en `etcd`.
   - **Arquitectura de Proveedor KMS v2:** Utiliza Cifrado de Sobre (Envelope Encryption). El `kube-apiserver` genera una clave local Data Encryption Key (DEK) para cifrar los secrets, y delega el cifrado de la DEK a un Key Management Service externo (AWS KMS, GCP Cloud KMS, Azure Key Vault, HashiCorp Vault) a través de un plugin de socket de dominio Unix. La Key Encryption Key (KEK) nunca sale del HSM/KMS.

2. **Capa de Control de Acceso (RBAC & Audit Logging):**
   - Los permisos directos `get`, `list`, `watch` sobre recursos `secrets` deben estar severamente restringidos.
   - Los vectores indirectos deben bloquearse: `pods/exec`, `pods/ephemeralcontainers`, `pods/log` y la creación de `serviceaccounts/token`.
   - Las reglas dedicadas de política `AuditEvent` deben registrar los patrones de acceso a datos sensibles sin registrar los datos reales del payload.

3. **Capa de Runtime e Inyección:**
   - **Variables de Entorno vs. Volume Mounts:** Las variables de entorno se filtran a través de procesos hijos, diagnósticos del sistema (`/proc/$PID/environ`), container crashes/core dumps y salidas de logs de aplicaciones. Los secrets montados como volúmenes respaldados por `tmpfs` (`medium: Memory`) residen puramente en la memoria RAM volátil y están aislados en el árbol de archivos del Pod.
   - **Projected ServiceAccount Tokens (TokenRequest API):** Reemplaza tokens de API estáticos de larga duración por JWTs de corta duración y vinculados a una audiencia (audience-bound), firmados por el proveedor OIDC del `kube-apiserver`.
   - **External Secrets Operator (ESO):** Desacopla el almacenamiento de secrets de Kubernetes. Sincroniza claves sensibles desde vaults externos directamente en Kubernetes secrets respaldados por `tmpfs` o los inyecta dinámicamente en pods en ejecución mediante Workload Identity Federation.

---

## 2. Fuentes de Referencia Oficiales
- **CNCF KCSA Curriculum:** [KCSA Curriculum Repository](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
- **Documentación de Kubernetes – Cifrado de Datos Confidenciales en Reposo:** [https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/)
- **Documentación de Kubernetes – Uso de un Proveedor KMS para Cifrado de Datos:** [https://kubernetes.io/docs/tasks/administer-cluster/kms-provider/](https://kubernetes.io/docs/tasks/administer-cluster/kms-provider/)
- **Documentación de Kubernetes – Proyección de Tokens de Service Account:** [https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/#service-account-token-projection](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/#service-account-token-projection)
- **Documentación de External Secrets Operator:** [https://external-secrets.io/latest/](https://external-secrets.io/latest/)

---

## 3. Ejercicios Prácticos Guiados de Laboratorio

### Ejercicio 1: Auditoría de la Exposición en Texto Plano de etcd y Configuración de `EncryptionConfiguration` (KMS / AES-CBC)

#### Objetivo
Demostrar cómo Kubernetes almacena secrets en `etcd` por defecto, configurar un manifiesto `EncryptionConfiguration` en el API Server, verificar el cifrado en el lado de escritura y realizar una re-encriptación/migración de secrets sin tiempo de inactividad (zero-downtime).

#### Paso 1.1: Crear un secret objetivo e inspeccionar el almacenamiento en bruto de etcd
Ejecutá los siguientes comandos para crear una credencial sensible en el namespace `production-sec` y consultar `etcdctl` directamente:

```bash
kubectl create namespace production-sec
kubectl create secret generic db-db-master-key \
  --from-literal=username='admin_db_user' \
  --from-literal=password='SuperSecretProductionP@ssw0rd2026!' \
  -n production-sec
```

Salida esperada:
```text
namespace/production-sec created
secret/db-db-master-key created
```

Consultá `etcd` directamente (asumiendo acceso al nodo master o host del control plane ejecutando etcd con certificados de cliente):

```bash
ETCDCTL_API=3 etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/production-sec/db-db-master-key
```

Salida esperada:
```text
/registry/secrets/production-sec/db-db-master-key
k8s

v1Secret
...
db-db-master-keyproduction-sec"*
passwordSuperSecretProductionP@ssw0rd2026!
admin_db_user
```
*(Notá que la cadena en texto plano `SuperSecretProductionP@ssw0rd2026!` se puede leer directamente dentro del payload de la clave de etcd).*

#### Paso 1.2: Generar una clave secreta de 32 bytes y construir el manifiesto `EncryptionConfiguration`
Creá una clave base64 de 32 bytes usando `head` y `openssl`:

```bash
BASE64_KEY=$(head -c 32 /dev/urandom | base64)
echo "Generated Key: ${BASE64_KEY}"
```

Salida esperada:
```text
Generated Key: c3VwZXJzZWNyZXRrZXlmb3Jrc2NhZXhhbXBsZTEyMzQ9
```

Creá el archivo de configuración en `/etc/kubernetes/enc/encryption-config.yaml`:

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: c3VwZXJzZWNyZXRrZXlmb3Jrc2NhZXhhbXBsZTEyMzQ9
      - identity: {}
```

#### Paso 1.3: Aplicar la configuración al `kube-apiserver` y realizar la Migración de Secrets
Actualizá el manifiesto del pod del `kube-apiserver` (`/etc/kubernetes/manifests/kube-apiserver.yaml`) para pasar la flag `--encryption-provider-config=/etc/kubernetes/enc/encryption-config.yaml` y montar el volumen del directorio dentro del contenedor del apiserver.

Una vez que el `kube-apiserver` se reinicie, probá el secret recién escrito versus el secret antiguo:

```bash
kubectl create secret generic new-api-token \
  --from-literal=token='Bearer-9876543210-SecretToken' \
  -n production-sec

ETCDCTL_API=3 etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/production-sec/new-api-token
```

Salida esperada:
```text
/registry/secrets/production-sec/new-api-token
k8s:enc:aescbc:v1:key1:%`V+ :... [Binary Encrypted Payload]
```

Re-cifrá los secrets existentes creados antes de habilitar el cifrado:

```bash
kubectl get secrets -A -o json | kubectl replace -f -
```

Salida esperada:
```text
secret/db-db-master-key replaced
secret/new-api-token replaced
...
```

---

#### Preguntas de Verificación – Ejercicio 1
1. **¿Por qué se incluye el proveedor `- identity: {}` al final de la lista `providers` en `EncryptionConfiguration`?**
2. **¿Qué ocurre durante un escenario de rotación de claves si se agrega una nueva clave (`key2`) por encima de `key1` en el bloque del proveedor `aescbc`, y cómo se desencadena la migración de los datos existentes?**

---

### Ejercicio 2: Comparación de las Mecánicas de Consumo de Secrets (Variables de Entorno vs Volume Mounts en RAM `tmpfs`) y Contención RBAC

#### Objetivo
Construir manifiestos de Pod de producción válidos que demuestren la inyección vulnerable de variables de entorno frente a volume mounts seguros en `tmpfs`, ejecutar inspecciones de diagnóstico en el árbol de procesos para probar los vectores de exposición de claves y aplicar un alcance RBAC mínimo para la lectura de secrets.

#### Paso 2.1: Desplegar cargas de trabajo que consumen Secrets a través de Variables de Entorno y Volume Mounts
Creá un archivo de despliegue `secrets-workload-demo.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: app-db-credentials
  namespace: production-sec
type: Opaque
stringData:
  DB_USER: "pg_app_user"
  DB_PASS: "P@ssw0rd_Vault_Protected_99"
---
apiVersion: v1
kind: Pod
metadata:
  name: insecure-env-pod
  namespace: production-sec
spec:
  containers:
    - name: app-container
      image: registry.k8s.io/e2e-test-images/agnhost:2.43
      command: ["sleep", "3600"]
      env:
        - name: DATABASE_PASSWORD
          valueFrom:
            secretKeyRef:
              name: app-db-credentials
              key: DB_PASS
---
apiVersion: v1
kind: Pod
metadata:
  name: secure-volume-pod
  namespace: production-sec
spec:
  containers:
    - name: app-container
      image: registry.k8s.io/e2e-test-images/agnhost:2.43
      command: ["sleep", "3600"]
      volumeMounts:
        - name: secret-volume
          mountPath: "/var/run/secrets/app"
          readOnly: true
  volumes:
    - name: secret-volume
      secret:
        secretName: app-db-credentials
        defaultMode: 0400
```

Aplicá el manifiesto:

```bash
kubectl apply -f secrets-workload-demo.yaml
```

Salida esperada:
```text
secret/app-db-credentials created
pod/insecure-env-pod created
pod/secure-volume-pod created
```

#### Paso 2.2: Realizar la Prueba de Diagnóstico de Filtraciones de Datos Sensibles
Inspeccioná las variables de entorno del proceso en `insecure-env-pod`:

```bash
kubectl exec -n production-sec insecure-env-pod -- cat /proc/1/environ | tr '\0' '\n' | grep DATABASE_PASSWORD
```

Salida esperada:
```text
DATABASE_PASSWORD=P@ssw0rd_Vault_Protected_99
```

Ahora inspeccioná el entorno del proceso y el almacenamiento montado en `secure-volume-pod`:

```bash
kubectl exec -n production-sec secure-volume-pod -- cat /proc/1/environ | tr '\0' '\n' | grep DATABASE_PASSWORD
```

Salida esperada:
```text
(empty output - variable does not exist in process environment)
```

Inspeccioná el tipo de sistema de archivos del volumen montado y los permisos de archivos:

```bash
kubectl exec -n production-sec secure-volume-pod -- df -T /var/run/secrets/app
kubectl exec -n production-sec secure-volume-pod -- ls -la /var/run/secrets/app
```

Salida esperada:
```text
Filesystem     Type  1K-blocks  Used Available Use% Mounted on
tmpfs          tmpfs   16258412     4  16258408   1% /var/run/secrets/app

total 4
drwxrwxrwt 3 root root  100 Aug  7 20:15 .
drwxr-xr-x 3 root root   17 Aug  7 20:15 ..
drwxr-xr-x 2 root root   60 Aug  7 20:15 ..2026_08_07_20_15_00.12345
lrwxrwxrwx 1 root root   31 Aug  7 20:15 ..data -> ..2026_08_07_20_15_00.12345
lrwxrwxrwx 1 root root   14 Aug  7 20:15 DB_PASS -> ..data/DB_PASS
lrwxrwxrwx 1 root root   14 Aug  7 20:15 DB_USER -> ..data/DB_USER
```

#### Paso 2.3: Aplicar Privilegio Mínimo Estricto de RBAC para el Acceso a Secrets
Definí un Role que otorgue acceso granular a secrets restringido por nombre de recurso, evitando la enumeración general (`list`/`watch` en todos los secrets):

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: restricted-secret-reader
  namespace: production-sec
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get"]
    resourceNames: ["app-db-credentials"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: bind-restricted-secret-reader
  namespace: production-sec
subjects:
  - kind: ServiceAccount
    name: default
    namespace: production-sec
roleRef:
  kind: Role
  name: restricted-secret-reader
  apiGroup: rbac.authorization.k8s.io
```

Probá los límites de acceso usando `kubectl auth can-i`:

```bash
kubectl auth can-i get secret/app-db-credentials -n production-sec --as=system:serviceaccount:production-sec:default
kubectl auth can-i list secrets -n production-sec --as=system:serviceaccount:production-sec:default
kubectl auth can-i get secret/db-db-master-key -n production-sec --as=system:serviceaccount:production-sec:default
```

Salida esperada:
```text
yes
no
no
```

---

#### Preguntas de Verificación – Ejercicio 2
1. **¿Por qué las variables de entorno no se actualizan cuando se edita un Secret actualizado en el API Server, mientras que los secrets montados por volumen se actualizan automáticamente?**
2. **Si un atacante adquiere permisos de `pods/exec` dentro de `secure-volume-pod`, ¿todavía puede leer el secret montado en `/var/run/secrets/app/DB_PASS`? ¿Qué control de seguridad secundario mitiga este vector?**

---

### Ejercicio 3: Identidad de Carga de Trabajo Moderna sin Secrets (Secretless Workload Identity) a través de Token Projection y Arquitectura de External Secrets Operator

#### Objetivo
Configurar tokens de ServiceAccount proyectados con audiencias personalizadas vinculadas y tiempos de expiración cortos, y analizar la arquitectura de integración de External Secrets Operator (ESO) con sistemas de gestión de claves en la nube.

#### Paso 3.1: Desplegar Pod con Token de ServiceAccount Proyectado
Creá `projected-token-pod.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault-auth-sa
  namespace: production-sec
---
apiVersion: v1
kind: Pod
metadata:
  name: vault-client-pod
  namespace: production-sec
spec:
  serviceAccountName: vault-auth-sa
  containers:
    - name: vault-agent
      image: registry.k8s.io/e2e-test-images/agnhost:2.43
      command: ["sleep", "3600"]
      volumeMounts:
        - name: vault-token
          mountPath: /var/run/secrets/tokens
          readOnly: true
  volumes:
    - name: vault-token
      projected:
        sources:
          - serviceAccountToken:
              audience: "https://vault.internal.net"
              expirationSeconds: 1200
              path: vault-identity-token
```

Aplicá y verificá las claims del payload del token:

```bash
kubectl apply -f projected-token-pod.yaml
TOKEN_CONTENT=$(kubectl exec -n production-sec vault-client-pod -- cat /var/run/secrets/tokens/vault-identity-token)
echo $TOKEN_CONTENT | jq -R 'split(".") | .[1] | @base64d | fromjson'
```

Salida esperada:
```json
{
  "aud": [
    "https://vault.internal.net"
  ],
  "exp": 1754603700,
  "iss": "https://kubernetes.default.svc.cluster.local",
  "kubernetes.io": {
    "namespace": "production-sec",
    "pod": {
      "name": "vault-client-pod",
      "uid": "a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d"
    },
    "serviceaccount": {
      "name": "vault-auth-sa",
      "uid": "f1e2d3c4-b5a6-9788-7766-554433221100"
    }
  },
  "nbf": 1754602500,
  "sub": "system:serviceaccount:production-sec:vault-auth-sa"
}
```

#### Paso 3.2: Analizar el Manifiesto de CRDs de External Secrets Operator (ESO)
Desplegar secrets estáticos en repositorios GitOps rompe la seguridad zero-trust. ESO sincroniza secrets dinámicamente desde proveedores externos de secrets utilizando la identidad del token proyectado:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault-backend
  namespace: production-sec
spec:
  provider:
    vault:
      server: "https://vault.internal.net"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "production-sec-vault-role"
          serviceAccountRef:
            name: vault-auth-sa
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: production-db-external-secret
  namespace: production-sec
spec:
  refreshInterval: "1h"
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: synced-db-secret
    creationPolicy: Owner
    template:
      engineVersion: v2
      metadata:
        annotations:
          security.cluster.local/managed-by: "external-secrets-operator"
  data:
    - secretKey: DB_PASSWORD
      remoteRef:
        key: production/database
        property: password
```

---

#### Preguntas de Verificación – Ejercicio 3
1. **¿Cómo la configuración de un campo `audience` personalizado en un `serviceAccountToken` proyectado defiende contra el robo de tokens y ataques de retransmisión (replay attacks) en otros servicios API del cluster?**
2. **En una arquitectura de External Secrets Operator, ¿qué le sucede al Kubernetes Secret nativo (`synced-db-secret`) si el Secret externo en HashiCorp Vault se rota, y qué controla la latencia de esta actualización?**

---

### Ejercicio 4: Audit Logging Avanzado y Caza de Amenazas (Threat Hunting) para el Acceso a Datos Sensibles

#### Objetivo
Configurar Políticas de Auditoría de la API de Kubernetes para rastrear la enumeración ilegal de Secrets y accesos anómalos, y ejecutar comandos de threat hunting contra los registros de auditoría (audit logs).

#### Paso 4.1: Construir una Política de Auditoría de Seguridad para Producción (`audit-policy.yaml`)
Creá `/etc/kubernetes/audit/audit-policy.yaml` con manejo explícito para recursos sensibles:

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  # Do not log secret data payloads, but log Metadata for all operations on Secrets
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]

  # Log RequestResponse for authorization checks to catch privilege escalation attempts
  - level: RequestResponse
    resources:
      - group: "authorization.k8s.io"
        resources: ["subjectaccessreviews", "selfsubjectaccessreviews"]

  # Log RequestHeader level for exec into pods (potential secret stealing vector)
  - level: RequestHeader
    resources:
      - group: ""
        resources: ["pods/exec", "pods/ephemeralcontainers"]

  # Default rule for all other resources
  - level: Metadata
    omitStages:
      - "RequestReceived"
```

#### Paso 4.2: Simular un Adversario Enumerando Secrets y Analizar las Trazas de Logs de Auditoría
Simulá la enumeración no autorizada de secrets a través de una service account:

```bash
kubectl get secrets -n production-sec --as=system:serviceaccount:production-sec:default
```

Consultá el log de auditoría del API Server (`/var/log/kubernetes/audit/audit.log`) para eventos sospechosos de listado masivo:

```bash
grep '"resources":["secrets"]' /var/log/kubernetes/audit/audit.log | jq '{
  timestamp: .stageTimestamp,
  user: .user.username,
  verb: .verb,
  namespace: .objectRef.namespace,
  resource: .objectRef.resource,
  status: .responseStatus.code,
  userAgent: .userAgent
}'
```

Salida esperada:
```json
{
  "timestamp": "2026-08-07T20:17:42Z",
  "user": "system:serviceaccount:production-sec:default",
  "verb": "list",
  "namespace": "production-sec",
  "resource": "secrets",
  "status": 403,
  "userAgent": "kubectl/v1.30.0 (linux/amd64) kubernetes/92a8320"
}
```

---

#### Preguntas de Verificación – Ejercicio 4
1. **¿Por qué está prohibido el nivel `level: RequestResponse` para recursos `secrets` en las políticas de auditoría estándar del API server de Kubernetes?**
2. **¿Qué combinación específica de verbo de API y subrecurso deberían monitorear los equipos de SRE/Seguridad para detectar sesiones de shell interactivas utilizadas para inspeccionar `/proc/$PID/environ` o secrets montados en memoria dentro de un Pod?**

---

## 4. Soluciones Integrales y Explicaciones Arquitectónicas

<details>
<summary><b>Haz clic para expandir las Soluciones y Explicaciones Arquitectónicas Profundas</b></summary>

### Respuestas y Explicaciones para el Ejercicio 1

1. **Ubicación del Proveedor `- identity: {}`:**
   - **Mecanismo:** La `EncryptionConfiguration` evalúa los proveedores secuencialmente de arriba a abajo durante las operaciones de **lectura** (read). Durante las operaciones de **escritura** (write), solo utiliza el *primer* proveedor del array (en este caso, `aescbc`).
   - **Necesidad Arquitectónica:** Agregar `- identity: {}` al final de la lista de proveedores garantiza la compatibilidad hacia atrás durante el despliegue inicial del cifrado. Permite al `kube-apiserver` leer secrets no cifrados existentes en `etcd` (gestionados por `identity: {}`) mientras cifra todos los secrets recién creados o actualizados con el proveedor primario (`aescbc`). Si se omitiera `identity: {}` antes de ejecutar la migración de secrets, la lectura de secrets heredados no cifrados fallaría con errores de descifrado.

2. **Protocolo de Rotación de Claves y Migración de Secrets:**
   - **Mecanismo:** Para rotar claves, se agrega una nueva clave (`key2`) como el elemento superior debajo del bloque del proveedor `aescbc`, moviendo `key1` a la segunda posición:
     ```yaml
     providers:
       - aescbc:
           keys:
             - name: key2
               secret: <new-base64-key>
             - name: key1
               secret: <old-base64-key>
     ```
   - **Mecánica de Lectura/Escritura:** El API Server usa `key2` para todas las nuevas escrituras. Al leer secrets existentes cifrados con `key1`, el API Server intenta con `key2`, falla, recurre (fallback) a `key1` y descifra exitosamente el payload.
   - **Desencadenante de la Migración:** Los secrets existentes permanecen cifrados con `key1` hasta que se vuelvan a escribir. Ejecutar `kubectl get secrets -A -o json | kubectl replace -f -` fuerza al API Server a leer cada secret (descifrando a través de `key1`) y reemplazarlo (cifrando a través de `key2`), completando la rotación de claves sin tiempo de inactividad (zero-downtime).

---

### Respuestas y Explicaciones para el Ejercicio 2

1. **Variables de Entorno vs. Actualizaciones Dinámicas en `tmpfs`:**
   - **Mecanismo:** Las variables de entorno se inyectan en el bloque de control del proceso (`struct mm_struct` en el kernel de Linux) estrictamente al inicializar el proceso (`execve`). Kubernetes no puede alterar el bloque de entorno de un proceso que ya se está ejecutando sin reiniciar el contenedor.
   - **Mecánica de Volume Mounts:** Los volume mounts de Kubernetes Secret utilizan `tmpfs` (sistema de archivos respaldado en RAM) gestionado por `kubelet`. Cuando un Secret cambia en `etcd`, `kubelet` recibe la actualización, crea un nuevo directorio con marca de tiempo dentro del volumen, actualiza los enlaces simbólicos (`..data` -> `..2026_08_07_...`) y realiza un intercambio atómico del acceso. Los procesos que observan eventos de cambio de archivos (por ejemplo, a través de `inotify`) reciben los datos del secret actualizados inmediatamente sin reiniciar los contenedores.

2. **Mitigación del Acceso `pods/exec` a Secrets Montados:**
   - **Impacto:** Si un atacante obtiene acceso `pods/exec` en `secure-volume-pod`, ejecuta código dentro del contexto de ejecución del contenedor y puede leer cualquier ruta de volumen que sea legible por el UID del usuario del proceso.
   - **Controles de Seguridad Secundarios:**
     - **Endurecimiento de RBAC:** Eliminar los permisos de `pods/exec` y `pods/attach` de los roles que no sean de administración (solo `verbs: ["get"]` en `pods`).
     - **Pod Security Standards (Perfil Restricted):** Aplicar `readOnlyRootFilesystem: true`, establecer explícitamente `runAsNonRoot: true` y eliminar todas las Linux capabilities (`capabilities: { drop: ["ALL"] }`).
     - **Aislamiento de Procesos y Controles de Admisión:** Desplegar perfiles de Seccomp (`runtime/default`) para bloquear llamadas al sistema (syscalls) de depuración (`ptrace`), e implementar herramientas de seguridad de runtime basadas en eBPF (ej., Tetragon, Falco) para generar alertas inmediatas si binarios no autorizados abren rutas de montaje sensibles (`/var/run/secrets/app`).

---

### Respuestas y Explicaciones para el Ejercicio 3

1. **Defensa por Restricción de Audiencia en Tokens Proyectados:**
   - **Mecanismo:** El token de ServiceAccount montado automáticamente por defecto tiene una audiencia por defecto igual al API server de Kubernetes (`https://kubernetes.default.svc`). Si un atacante roba este token, puede retransmitirlo (replay) contra el API server del cluster para realizar operaciones autorizadas.
   - **Valor de Seguridad de la Audiencia Personalizada:** Cuando se especifica `audience: "https://vault.internal.net"`, el emisor del token firma el JWT con `aud: ["https://vault.internal.net"]`. Si este token se filtra y se presenta ante el API server de Kubernetes u otro servicio interno, la API receptora rechaza el token porque la claim `aud` no coincide con el validador de identidad del servicio objetivo.

2. **Latencia de Rotación en External Secrets Operator:**
   - **Mecanismo:** ESO ejecuta un bucle de controlador (controller loop) que observa los recursos personalizados `ExternalSecret`. Cuando se actualiza un secret en HashiCorp Vault, ESO lee el nuevo payload al expirar el `refreshInterval` configurado (ej., `refreshInterval: "1h"`).
   - **Actualización del Objetivo:** ESO actualiza los campos de datos del Kubernetes Secret nativo objetivo (`synced-db-secret`). Una vez que el Secret nativo es actualizado por ESO, `kubelet` actualiza automáticamente los archivos del volumen `tmpfs` montados dentro de los pods de la aplicación consumidora dentro del siguiente período de sincronización de `kubelet` (típicamente ~60 segundos).

---

### Respuestas y Explicaciones para el Ejercicio 4

1. **Prohibición de `level: RequestResponse` para Secrets:**
   - **Mecanismo:** El registro de auditoría en nivel `RequestResponse` graba el cuerpo completo de la solicitud HTTP (request body) y el cuerpo de la respuesta HTTP (response body) para las solicitudes de la API.
   - **Riesgo de Seguridad:** Para recursos de tipo `secrets`, el cuerpo de la respuesta HTTP contiene los valores del secret en Base64 decodificados en texto plano. Configurar el audit logging en `RequestResponse` para secrets escribe todas las contraseñas, tokens y claves privadas en texto claro directamente en los archivos de log de auditoría (`/var/log/kubernetes/audit/audit.log`), exponiendo datos sensibles a agregadores de logs (Elasticsearch, Datadog, SIEM) y operadores de almacenamiento de logs. Se debe utilizar strictly `level: Metadata` para los secrets.

2. **Monitoreo de Sesiones de Shell Interactivas:**
   - **Recurso de API y Verbo:** Los equipos de seguridad deben monitorear las solicitudes dirigidas al subrecurso `pods/exec` o `pods/ephemeralcontainers` con los verbos `create` o `get`.
   - **Filtro de Detección de Auditoría:**
     ```json
     {
       "verb": "create",
       "objectRef": {
         "resource": "pods",
         "subresource": "exec"
       }
     }
     ```
   - **Mecánica Forense en Runtime:** Una llamada a `exec` ejecuta una terminal interactiva (`sh`, `bash`) dentro de los namespaces del contenedor objetivo, proporcionando acceso interactivo directo a `/proc/1/environ`, la memoria de entorno del sistema y los directorios de secrets montados en `tmpfs`. El monitoreo de este evento permite la detección inmediata de movimientos laterales y operaciones de descubrimiento de secrets.

</details>