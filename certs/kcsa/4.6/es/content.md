# Tema 4.6: Acceso a Datos Sensibles

## 1. Motivación y Problema Arquitectónico de Producción

En un entorno Kubernetes cloud-native, los datos sensibles —incluyendo tokens de API, claves privadas TLS, credenciales de base de datos y semillas criptográficas— representan el objetivo principal para actores maliciosos que realizan movimiento lateral y escalación de privilegios. Administrados de forma incorrecta, los datos sensibles se vuelven accesibles a través de múltiples superficies de ataque en el control plane, el runtime del nodo, los backends de almacenamiento y los procesos de las aplicaciones.

```
                     +-------------------------------------------------------------+
                     |                Control Plane Attack Surface                 |
                     |                                                             |
                     |   [ API Request ] ---> [ RBAC Check ]                       |
                     |                             |                               |
                     |                             v                               |
                     |                  [ etcd Storage Backend ]                   |
                     |                 (Unencrypted at Rest Risk)                  |
                     +-----------------------------+-------------------------------+
                                                   |
                                                   v
                     +-------------------------------------------------------------+
                     |                 Node Runtime Attack Surface                 |
                     |                                                             |
                     |   [ kubelet ] ---> [ Pod Spec Injection ]                   |
                     |                           |                                 |
                     |           +---------------+---------------+                 |
                     |           |                               |                 |
                     |           v                               v                 |
                     |  [ Environment Variables ]       [ Volume Mounts ]          |
                     |  - Leak via /proc/$PID/environ   - Written to Disk/tmpfs   |
                     |  - Leak via Crash Dumps          - File Permission Risks    |
                     |  - Leak via Stack Traces                                    |
                     +-------------------------------------------------------------+
```

### Riesgos Críticos de Producción y Vectores de Amenaza

1. **Almacenamiento no encriptado en reposo en etcd:**
   Por defecto, Kubernetes almacena objetos en etcd en texto plano (codificados como Protobuf o JSON). Si un atacante obtiene acceso directo (raw) a snapshots de etcd, respaldos de Persistent Volumes o a los dispositivos de almacenamiento en bloque del host subyacente, todos los objetos `Secret` a lo largo del cluster quedan comprometidos sin necesidad de autenticación en el control plane.

2. **Secrets mediante Variables de Entorno:**
   Inyectar secrets como variables de entorno (`env.valueFrom.secretKeyRef`) es un antipatrón ampliamente extendido en sistemas de producción debido a la exposición en runtime:
   - **Inspección de Procesos:** Cualquier usuario o proceso de diagnóstico dentro del contenedor puede leer `/proc/1/environ` o ejecutar `env`/`printenv`.
   - **Filtración (Leakage) en Subprocesos:** Las variables de entorno son heredadas automáticamente por procesos hijo creados, librerías de terceros y ejecuciones de shell.
   - **Logs y Crash Dumps:** Las caídas de aplicaciones, stack traces de excepciones no controladas y agentes de rastreo APM capturan frecuentemente la tabla de variables de entorno del proceso y la exportan a stacks de logs centralizados (ej. Elasticsearch, Datadog).

3. **RBAC de ServiceAccount con Exceso de Privilegios:**
   Asignar permisos amplios (tales como `get`, `list`, `watch` en `secrets` a nivel de `ClusterRole`) permite que workloads comprometidos o ServiceAccounts de CI/CD comprometidas extraigan (scrape) todos los secrets del cluster. Las reglas comodín (`verbs: ["*"]`, `resources: ["*"]`) eliminan los límites de privilegio.

4. **Riesgos de Persistencia en Memoria y Almacenamiento:**
   Cuando los secrets son montados como archivos, los volúmenes de `Secret` estándar de Kubernetes utilizan un almacenamiento de respaldo `in-memory` (`tmpfs`). Sin embargo, si la RAM del nodo experimenta una fuerte presión de memoria, los secrets guardados en memoria pueden ser transferidos a particiones de swap no encriptadas del nodo (`/dev/swap`) o incluirse en core dumps del kernel no encriptados (`/var/crash`).

5. **Falta de Sincronización de Ciclo de Vida y Rotación de Secrets:**
   Los objetos `Secret` estándar de Kubernetes carecen de capacidades integradas de auto-rotación. Cuando las credenciales en una autoridad externa (ej. HashiCorp Vault, AWS Secrets Manager) cambian, los secrets estáticos de Kubernetes quedan desactualizados, forzando peligrosas actualizaciones manuales o scripts personalizados que arriesgan interrupciones operativas.

---

## 2. Comparativas Técnicas y Tablas de Trade-offs

### 2.1 Arquitecturas de Inyección de Secrets

| Patrón de Arquitectura | Postura de Seguridad | Complejidad Operativa | Capacidades de Rotación | Rendimiento y Latencia | Radio de Impacto de Falla |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Variables de Entorno (`envFrom` / `secretKeyRef`)** | **Baja:** Expuestas en `/proc/$PID/environ`, crash dumps, logs y árboles de procesos hijo. | **Baja:** Funcionalidad nativa de Kubernetes; no requiere controladores externos. | **Ninguna:** Requiere reinicio/recreación del pod para obtener los valores actualizados. | **Óptima:** Inyectada al inicio del pod; cero llamadas a la API en runtime. | Alto (Credenciales estáticas fácilmente filtradas a través de logs). |
| **Volúmenes `tmpfs` Montados (`spec.volumes.secret`)** | **Media-Alta:** Aislada a permisos de sistema de archivos (`defaultMode: 0400`), memoria no persistente. | **Baja:** Característica nativa de Kubernetes soportada por `kubelet`. | **Parcial:** `kubelet` sincroniza actualizaciones al volumen, pero la aplicación debe monitorear eventos de archivos. | **Alta:** Lecturas mapeadas en memoria desde el `tmpfs` del nodo. | Medio (Limitado a la ruta del sistema de archivos dentro del contenedor). |
| **External Secrets Operator (ESO)** | **Alta:** Secrets nativos sincronizados dinámicamente desde Vault/AWS/GCP con RBAC de grano fino. | **Media:** Requiere instalar los CRD del controlador ESO y administrar tokens de autenticación. | **Alta:** El bucle de reconciliación nativo actualiza automáticamente los recursos `Secret` de Kubernetes. | **Alta:** Lecturas locales; la sincronización ocurre fuera de banda mediante el bucle de control del operator. | Medio (Crea objetos Secret de K8s estándar en etcd). |
| **Secrets Store CSI Driver** | **Muy Alta:** Contenido de secrets obtenido bajo demanda; no persistencia opcional en etcd. | **Alta:** Requiere DaemonSet del driver CSI, plugins de proveedores y CRDs `SecretProviderClass`. | **Muy Alta:** La auto-rotación actualiza los archivos montados dinámicamente en `tmpfs`. | **Media:** Latencia en el montaje del almacenamiento al iniciar el pod debido a llamadas gRPC externas. | Bajo (No se almacena ningún objeto Secret en etcd si la sincronización con etcd está deshabilitada). |
| **Integración Directa mediante SDK (ej. Vault SDK)** | **Máxima:** Sin datos sensibles almacenados en disco o etcd; credenciales retenidas solo en la memoria de la app. | **Muy Alta:** Requiere refactorización del código de la aplicación; acoplamiento fuerte a la API del proveedor de secrets. | **Máxima:** La aplicación gestiona la renovación dinámica de arrendamientos (leases) y la rotación de tokens en RAM. | **Baja-Media:** Latencia de red en el arranque de la app y en los ciclos de renovación de tokens. | Aislado (Limitado estrictamente al runtime del proceso de la aplicación). |

---

### 2.2 Proveedores de Encriptación en Reposo para etcd

| Proveedor de Encriptación | Algoritmo Criptográfico | Ubicación del Almacenamiento de Claves | Complejidad de Rotación | Cobertura del Modelo de Amenazas | Sobrecarga de Rendimiento |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`identity` (Por defecto)** | Ninguno (Texto plano / Protobuf) | Base de datos etcd | N/A | Ninguna | Cero |
| **`aescbc`** | AES-CBC con relleno (padding) PKCS#7 | Texto plano en el archivo `EncryptionConfiguration` en el host del control plane | **Alta:** Modificación manual del archivo en dos fases y reinicios del servidor API | Protege contra el robo directo del disco etcd. Vulnerable si el disco del control plane está comprometido. | Muy Baja |
| **`secretbox`** | XSalsa20 y Poly1305 | Texto plano en el archivo `EncryptionConfiguration` en el host del control plane | **Alta:** Manipulación manual del archivo de claves y rolling updates del control plane | Protege contra el robo directo del disco etcd. | Muy Baja |
| **`kms` (v2)** | AES-GCM-256 (DEK) encriptada por Remote Envelope Key (KEK) | KMS remoto en la nube (AWS KMS, GCP KMS, Vault, Azure Key Vault) | **Baja:** Rotación automatizada de KEK gestionada de forma remota; generación automatizada de DEK | Protección total contra el robo de etcd, robo del disco del control plane y compromiso de snapshots. | Baja (Las DEK se almacenan localmente en memoria caché por el plugin KMS v2). |

---

## 3. Manifiestos de Infraestructura y Workloads Listos para Producción

### 3.1 Configuración de Encriptación del Control Plane (`EncryptionConfiguration` KMS v2)

El siguiente manifiesto configura `kube-apiserver` para encriptar todos los objetos `Secret` en etcd utilizando un proveedor gRPC KMS v2, recurriendo a `aescbc` como alternativa para las transiciones de claves, con `identity` en la parte inferior para permitir la desencriptación de datos heredados no encriptados.

Guardar como `/etc/kubernetes/etcd-encryption/encryption-config.yaml` en los nodos del control plane:

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
      - configmaps
    providers:
      - kms:
          apiVersion: v2
          name: vault-kms-provider
          endpoint: unix:///var/run/kmsplugin/kms.sock
          timeout: 3s
      - aescbc:
          keys:
            - name: key-20260807
              secret: dGhpcyBpcyBhIDMyIGJ5dGUgYWVzIGtleSBleGFtcGxlIQ==
      - identity: {}
```

---

### 3.2 Integración de Arquitectura con External Secrets Operator (ESO)

Este manifiesto establece un `SecretStore` aislado que se autentica en HashiCorp Vault mediante la proyección de volumen de tokens de ServiceAccount de Kubernetes (ServiceAccount Token Volume Projection), seguido de un recurso `ExternalSecret` que sincroniza las credenciales de la base de datos de producción en un `Secret` nativo de Kubernetes.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: eso-vault-auth-sa
  namespace: production
---
apiVersion: v1
kind: Secret
metadata:
  name: eso-vault-auth-sa-token
  namespace: production
  annotations:
    kubernetes.io/service-account.name: eso-vault-auth-sa
type: kubernetes.io/service-account-token
---
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault-backend-store
  namespace: production
spec:
  provider:
    vault:
      server: "https://vault.internal.example.com:8200"
      path: "secret"
      version: "v2"
      caProvider:
        type: ConfigMap
        name: internal-ca-bundle
        key: ca.crt
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "production-app-role"
          secretRef:
            name: eso-vault-auth-sa-token
            key: token
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: production-db-credentials-sync
  namespace: production
spec:
  refreshInterval: "1h"
  secretStoreRef:
    name: vault-backend-store
    kind: SecretStore
  target:
    name: production-db-credentials
    creationPolicy: Owner
    template:
      type: Opaque
      metadata:
        labels:
          app.kubernetes.io/managed-by: external-secrets
        annotations:
          security.kubernetes.io/sensitive: "true"
      data:
        DB_USERNAME: "{{ .username }}"
        DB_PASSWORD: "{{ .password }}"
  data:
    - secretKey: username
      remoteRef:
        key: production/database/config
        property: db_user
    - secretKey: password
      remoteRef:
        key: production/database/config
        property: db_pass
```

---

### 3.3 Deployment de Workload utilizando Secrets Store CSI Driver con `tmpfs`

Este deployment de producción monta credenciales sensibles en un volumen respaldado por memoria (`tmpfs`) a través del Secrets Store CSI Driver. Deshabilita explícitamente la sincronización con etcd, evitando la persistencia de contenido sensible en etcd, e impone contextos de seguridad estrictos (`readOnlyRootFilesystem`, ejecución como usuario no-root, `seccompProfile`).

```yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: vault-db-csi-provider
  namespace: production
spec:
  provider: vault
  parameters:
    vaultAddress: "https://vault.internal.example.com:8200"
    roleName: "production-app-role"
    objects: |
      - objectName: "db-username"
        secretPath: "secret/data/production/database/config"
        secretKey: "db_user"
      - objectName: "db-password"
        secretPath: "secret/data/production/database/config"
        secretKey: "db_pass"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: secure-api-service
  namespace: production
  labels:
    app.kubernetes.io/name: secure-api-service
    app.kubernetes.io/part-of: payment-gateway
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: secure-api-service
  template:
    metadata:
      labels:
        app.kubernetes.io/name: secure-api-service
    spec:
      serviceAccountName: eso-vault-auth-sa
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: api-container
          image: registry.example.com/payment/api:v2.4.1
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
          volumeMounts:
            - name: secrets-store-inline
              mountPath: "/mnt/secrets/db"
              readOnly: true
          ports:
            - containerPort: 8443
              name: https
      volumes:
        - name: secrets-store-inline
          csi:
            driver: secrets-store.csi.k8s.io
            readOnly: true
            volumeAttributes:
              secretProviderClass: "vault-db-csi-provider"
```

---

### 3.4 Manifiesto RBAC de Mínimo Privilegio para Acceso a Secrets

Esta especificación RBAC otorga acceso de lectura estricto a un único recurso `Secret` específico para un controlador operator, mientras bloquea la escalación por comodines (wildcard) a nivel de todo el cluster.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: db-credential-reader
  namespace: production
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["production-db-credentials"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: bind-db-credential-reader
  namespace: production
subjects:
  - kind: ServiceAccount
    name: eso-vault-auth-sa
    namespace: production
roleRef:
  kind: Role
  name: db-credential-reader
  apiGroup: rbac.authorization.k8s.io
```

---

## 4. Comandos CLI Reales y Salidas de Terminal

### 4.1 Verificación de la Encriptación en Reposo de etcd

#### Comando 1: Creación de un Secret de prueba en el cluster
```bash
$ kubectl create secret generic production-api-key \
  --namespace=production \
  --from-literal=api-token="SECURE_TOKEN_VALUE_2026_KCSA"
```
```output
secret/production-api-key created
```

#### Comando 2: Consulta directa al almacenamiento en bruto de etcd mediante `etcdctl` para verificar la encriptación
```bash
$ ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
  get /registry/secrets/production/production-api-key
```
```output
/registry/secrets/production/production-api-key
k8s:enc:kms:v2:vault-kms-provider:7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a...[BINARY KMS DEK DATA]...
```

*Análisis:* El prefijo de salida `k8s:enc:kms:v2:vault-kms-provider:` demuestra que el contenido del secret almacenado en la clave `/registry/secrets/production/production-api-key` está completamente encriptado por KMS v2. Los secrets no encriptados muestran texto ASCII Protobuf estándar que contiene `apiVersion` y claves en texto plano.

---

### 4.2 Demostración de la Amenaza de Filtración de Variables de Entorno en Procesos

#### Comando 1: Ejecución dentro de un contenedor mal configurado con referencias a secrets en variables de entorno
```bash
$ kubectl exec -n production deployment/vulnerable-api-service -- cat /proc/1/environ | tr '\0' '\n' | grep DB_
```
```output
DB_USERNAME=admin_user
DB_PASSWORD=SuperSecretPassWord123!
DB_HOST=prod-db.internal.net
```

#### Comando 2: Inspección del montaje en el sistema de archivos en la configuración de pod seguro con el driver CSI
```bash
$ kubectl exec -n production deployment/secure-api-service -- ls -la /mnt/secrets/db
```
```output
total 0
drwxrwxrwt 2 root root  80 Aug  7 20:25 .
drwxr-xr-x 3 root root  16 Aug  7 20:25 ..
-r--r--r-- 1 root root  10 Aug  7 20:25 db-password
-r--r--r-- 1 root root  10 Aug  7 20:25 db-username
```

#### Comando 3: Verificación de que el almacenamiento de respaldo del volumen es `tmpfs` (RAM) dentro del nodo host del contenedor
```bash
$ kubectl exec -n production deployment/secure-api-service -- df -T /mnt/secrets/db
```
```output
Filesystem           Type       1K-blocks      Used Available Use% Mounted on
tmpfs                tmpfs        8153408         4   8153404   1% /mnt/secrets/db
```

---

### 4.3 Auditoría de Acceso a Secrets a través de Logs de Auditoría de Kubernetes

#### Comando 1: Consulta de logs de auditoría para peticiones de alto riesgo `get`/`list` sobre Secrets utilizando `jq`
```bash
$ tail -n 1000 /var/log/kubernetes/audit/audit.log | jq -r '
  select(.objectRef.resource=="secrets" and (.verb=="list" or .verb=="get")) |
  [.stageTimestamp, .user.username, .verb, .objectRef.namespace, .objectRef.name, .responseStatus.code] |
  @tsv'
```
```output
2026-08-07T20:28:12Z    system:serviceaccount:production:unauthorized-sa    list    production    <nil>   403
2026-08-07T20:29:45Z    kubernetes-admin    get    production    production-api-key    200
2026-08-07T20:31:02Z    system:serviceaccount:production:eso-vault-auth-sa    get    production    production-db-credentials    200
```

---

### 4.4 Verificación de Restricciones de Acceso RBAC

#### Comando: Prueba de acceso a la API mediante `kubectl auth can-i`
```bash
$ kubectl auth can-i list secrets \
  --namespace=production \
  --as=system:serviceaccount:production:eso-vault-auth-sa
```
```output
no
```

```bash
$ kubectl auth can-i get secrets/production-db-credentials \
  --namespace=production \
  --as=system:serviceaccount:production:eso-vault-auth-sa
```
```output
yes
```

---

## 5. Guía de Verificación y Diagnóstico de Fallas

### 5.1 Árbol de Decisión: Diagnóstico de Fallas en la Encriptación en Reposo con KMS

```
                     +---------------------------------------------------+
                     | kube-apiserver fails to start or Secret creation |
                     | throws "Internal error occurred: KMS provider..." |
                     +-------------------------+-------------------------+
                                               |
                                               v
                     +---------------------------------------------------+
                     | Inspect /var/log/pods/kube-system_kube-apiserver |
                     | or control plane journalctl -u kube-apiserver     |
                     +-------------------------+-------------------------+
                                               |
              +--------------------------------+--------------------------------+
              |                                                                 |
              v                                                                 v
+---------------------------+                                     +---------------------------+
| Error: "connection refused"|                                     | Error: "kms provider      |
| or "no such file/directory"|                                     | operation timed out"      |
+-------------+-------------+                                     +-------------+-------------+
              |                                                                 |
              v                                                                 v
+---------------------------+                                     +---------------------------+
| Check UNIX domain socket: |                                     | Check upstream KMS health:|
| Is the KMS plugin daemon  |                                     | Vault/Cloud KMS latency,  |
| running on host?          |                                     | network egress policies,  |
| Is socket volume-mounted  |                                     | IAM authorization status. |
| into apiserver pod spec?  |                                     +---------------------------+
+---------------------------+
```

---

### 5.2 Comandos de Diagnóstico y Flujo de Trabajo para la Resolución de Problemas (Troubleshooting)

#### Problema 1: Falla en la Conexión del Plugin KMS
**Síntoma:** `kubectl create secret` falla con `rpc error: code = Unavailable desc = connection error: desc = "transport: Error while dialing dialect...`.

1. Verificar si el socket del plugin KMS existe en el host:
   ```bash
   $ ls -la /var/run/kmsplugin/kms.sock
   ```
   *Salida Esperada:* `srw-rw---- 1 root root 0 Aug 7 20:00 /var/run/kmsplugin/kms.sock`

2. Verificar el montaje `hostPath` en `/etc/kubernetes/manifests/kube-apiserver.yaml`:
   ```yaml
   volumeMounts:
     - mountPath: /var/run/kmsplugin/kms.sock
       name: kms-socket
   volumes:
     - hostPath:
         path: /var/run/kmsplugin/kms.sock
         type: Socket
       name: kms-socket
   ```

---

#### Problema 2: Falla de Sincronización en ExternalSecret (Error de `SecretStore`)
**Síntoma:** El estado de `ExternalSecret` muestra `SecretSyncedError`.

1. Inspeccionar los status conditions del CRD `ExternalSecret`:
   ```bash
   $ kubectl get externalsecret production-db-credentials-sync \
     --namespace=production \
     -o jsonpath='{.status.conditions[?(@.type=="Ready")]}' | jq
   ```
   ```output
   {
     "lastTransitionTime": "2026-08-07T20:35:10Z",
     "message": "can not config provider client: vault access denied: permission denied for path secret/data/production/database/config",
     "reason": "SecretStoreUnavailable",
     "status": "False",
     "type": "Ready"
   }
   ```

2. Validar la alineación del rol de autenticación en Vault:
   Asegurar que el namespace del token de ServiceAccount coincida con el rol de autenticación vinculado configurado dentro de las políticas de HashiCorp Vault:
   ```bash
   $ vault read auth/kubernetes/role/production-app-role
   ```

---

#### Problema 3: Fallas en el Montaje del Secrets Store CSI Driver
**Síntoma:** Pod atascado en estado `ContainerCreating`.

1. Inspeccionar los eventos del Pod:
   ```bash
   $ kubectl describe pod -l app.kubernetes.io/name=secure-api-service -n production
   ```
   ```output
   Events:
     Type     Reason       Age    From               Message
     ----     ------       ----   ----               -------
     Warning  FailedMount  12s    kubelet            MountVolume.SetUp failed for volume "secrets-store-inline" : rpc error: code = Unknown desc = failed to mount secrets store objects for pod production/secure-api-service-7d8f9b6c-x4z12, err: error mounting target "/var/lib/kubelet/pods/.../volumes/kubernetes.io~csi/secrets-store-inline/mount": provider "vault" not registered
   ```

2. Solución: Verificar que el DaemonSet del proveedor específico (ej. `csi-secrets-store-provider-vault`) esté activo en el nodo:
   ```bash
   $ kubectl get daemonset -n kube-system -l app.kubernetes.io/name=csi-secrets-store-provider-vault
   ```
   ```output
   NAME                               READY   DESIRED   CURRENT   UP-TO-DATE   AVAILABLE   AGE
   csi-secrets-store-provider-vault   5       5         5         5            5           42d
   ```

---

## 6. Referencias

- [CNCF KCSA Curriculum GitHub Repository](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
- [Kubernetes Official Documentation: Encrypting Secret Data at Rest](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/)
- [Kubernetes Official Documentation: KMS v2 Provider Configuration](https://kubernetes.io/docs/tasks/administer-cluster/kms-provider/)
- [External Secrets Operator (ESO) Architecture & Docs](https://external-secrets.io/latest/)
- [Kubernetes Secrets Store CSI Driver Documentation](https://secrets-store-csi-driver.sigs.k8s.io/)
- [Kubernetes Official Documentation: Controlling Access to Secrets](https://kubernetes.io/docs/concepts/configuration/secret/#information-security-for-secrets)
- [OWASP Kubernetes Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Kubernetes_Security_Cheat_Sheet.html)