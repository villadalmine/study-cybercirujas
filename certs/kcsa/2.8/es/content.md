# KCSA Study Guide: Tema 2.8 – Seguridad y Arquitectura de etcd

---

## 1. Motivación y Problema de Arquitectura de Producción

### 1.1 El Rol de etcd en los Límites de Seguridad de Kubernetes
etcd es un almacén clave-valor distribuido y fuertemente consistente que implementa el **algoritmo de consenso Raft**. En un cluster de Kubernetes, etcd sirve como la única fuente de verdad (`state store`). Cada objeto de API—incluidos `Pods`, `ServiceAccounts`, `RBAC Roles`, `CRDs` y `Secrets`—se serializa como JSON o Protocol Buffers y se almacena bajo el prefijo de clave `/registry`.

Desde una perspectiva de modelado de amenazas zero-trust, etcd se ubica completamente fuera de los subsistemas de RBAC, Admission Controller y Audit Logging de Kubernetes:
* **Evasión de Controles de la API de Kubernetes:** Si un actor malicioso o un proceso comprometido obtiene acceso de red o de sistema de archivos local a etcd, puede leer o modificar el estado del cluster directamente. Puede falsificar privilegios de cluster-admin, extraer tokens de service account, inyectar contenedores maliciosos o extraer datos sin cifrar (`raw`) de `Secrets` sin activar un solo evento de auditoría de la API de Kubernetes.
* **Amenazas en la Capa de Almacenamiento:** etcd escribe datos en un Write-Ahead Log (`WAL`) y genera periódicamente archivos de snapshot en el disco del host (típicamente bajo `/var/lib/etcd`). Por defecto, etcd almacena claves y valores en texto plano sin cifrar dentro de su archivo de base de datos `bbolt` (`member/snap/db`). Un snapshot de disco filtrado, un backup sin cifrar o una lectura no autorizada de volumen expone instantáneamente todas las credenciales del cluster.

```
+-----------------------------------------------------------------------------------+
|                                KUBERNETES CONTROL PLANE                           |
|                                                                                   |
|  +---------------------+      +---------------------+      +-------------------+  |
|  |  kubectl / Client   | ---> |   kube-apiserver    | ---> |    kubelet        |  |
|  +---------------------+      |  (RBAC, Admission,  |      +-------------------+  |
|                               |   Audit Logs)       |                             |
|                               +---------------------+                             |
|                                          |                                        |
|                                    mTLS  | Port 2379                              |
|                                          v                                        |
|                               +---------------------+                             |
|                               |     etcd Cluster    |                             |
|                               |  (Raft Consensus)   |                             |
|                               +---------------------+                             |
+------------------------------------------|----------------------------------------+
                                           | Direct Storage Access (ATTACK VECTOR)
                                           v
                              +-------------------------+
                              | /var/lib/etcd/member/db |
                              | (Unencrypted DB / WAL)  |
                              +-------------------------+
```

### 1.2 Mecánica de Consenso Raft y Consideraciones de Quórum
etcd mantiene la consistencia del estado a través de múltiples nodos mediante el protocolo Raft. Un cluster requiere una **mayoría estricta (quórum)** para realizar transiciones de estado:

$$\text{Quorum Size} = \left\lfloor \frac{N}{2} \right\rfloor + 1$$

Donde $N$ es el número total de miembros en el cluster.

| Miembros Totales ($N$) | Quórum Requerido | Tolerancia Máxima a Fallas |
|---|---|---|
| 1 | 1 | 0 |
| 3 | 2 | 1 |
| 5 | 3 | 2 |
| 7 | 4 | 3 |

**Compromiso de SRE en Producción:** Incrementar el tamaño del cluster a 5 nodos mejora la tolerancia a fallas, pero aumenta el overhead de tiempo de ida y vuelta (round-trip) de la red durante la replicación de entradas de log (RPCs `AppendEntries`). Además, cada nodo adicional expande la superficie de ataque para la gestión de certificados TLS y la exposición de volúmenes físicos.

### 1.3 Arquitectura de Envelope Encryption
Para proteger recursos sensibles de la API (como `Secrets`) en reposo sin incurrir en un enorme overhead de rendimiento en etcd mismo, Kubernetes implementa **Envelope Encryption**:

1. **Data Encryption Key (DEK):** Generada localmente por `kube-apiserver` (o un plugin KMS) para cifrar el payload de la API original utilizando AES-GCM o AES-CBC.
2. **Key Encryption Key (KEK):** Gestionada externamente dentro de un módulo de seguridad de hardware (HSM) o KMS en la nube (ej., AWS KMS, HashiCorp Vault, Azure Key Vault). La KEK cifra la DEK.
3. **Estructura del Payload:** `kube-apiserver` escribe la DEK cifrada y el payload cifrado en etcd bajo la clave de destino. etcd mismo permanece sin conocimiento de las claves de descifrado.

---

## 2. Comparativas Técnicas y Tablas de Compromisos

### 2.1 Matriz de Proveedores de Cifrado de Secrets de Kubernetes

| Proveedor | Mecanismo | Rendimiento / Latencia | Complejidad de Rotación de Claves | Postura de Seguridad | Recomendación para Producción |
|---|---|---|---|---|---|
| `identity` | Almacenamiento en texto plano (por defecto) | Overhead cero | N/A | **Riesgo Crítico**: Texto plano en la BD `bbolt` de etcd. | Nunca usar en Producción |
| `aescbc` | AES-CBC con relleno PKCS#7 | Overhead muy bajo | Manual (requiere actualizaciones de configuración y re-cifrado de secrets del cluster) | **Riesgo Medio**: Vulnerable a ataques de padding oracle si el manejo de IV es defectuoso; la clave reside en un archivo estático. | Aceptable para despliegues bare-metal pequeños o aislados |
| `secretbox` | XSalsa20 y Poly1305 | Overhead bajo | Manual (requiere reemplazo estático de clave) | **Alto**: Cifrado autenticado fuerte; la clave reside en un archivo. | Alternativa a AES en arquitecturas sin AES-NI |
| `aesgcm` | AES-GCM con nonce aleatorio | Overhead bajo | Manual (tamaño de clave limitado, riesgo de reutilización de nonce si se gestiona mal) | **Alto**: Cifrado autenticado (AEAD); clave estática almacenada en el disco del host. | Adecuado para requerimientos de AEAD con clave estática |
| `kms` (v2) | KMS externo vía gRPC Unix Domain Socket | Sub-milisegundo (DEK en caché en memoria por el APIServer) | **Automatizado**: KEK rotada en KMS; DEK rotada automáticamente sin reiniciar el APIServer | **Máximo**: Claves respaldadas por HSM/Vault; DEKs selladas por KEK; registro de auditoría completo del acceso a claves. | **Estándar Obligatorio para Producción Empresarial** |

### 2.2 Comparación de Estrategias de Hardening de etcd

| Capa de Hardening | Método de Implementación | Amenaza Mitigada | Impacto en Rendimiento | Complejidad Operativa |
|---|---|---|---|---|
| **Peer mTLS** | CA interna dedicada o autofirmada con validación SAN | Nodo no autorizado uniéndose al cluster Raft, escucha ilegal del tráfico de replicación. | Bajo (overhead de handshake TLS en el inicio de la conexión) | Alta (Requiere PKI interna y gestión de rotación de certificados) |
| **Client mTLS** | Certificados de cliente dedicados de `kube-apiserver` (`--client-cert-auth=true`) | Consultas directas de clientes no autorizadas al puerto 2379. | Bajo | Alta (Los certificados deben tener un alcance delimitado strictly y monitorearse por expiración) |
| **Network Isolation** | VLAN dedicada / CNI `NetworkPolicy` / Firewall del Host (iptables/nftables) | Escaneo directo de red e intentos de conexión no autorizados a los puertos 2379/2380. | Despreciable | Baja a Media |
| **Localhost Binding** | `--listen-client-urls=https://127.0.0.1:2379` | Ataques de red remotos en nodos del control plane. | Cero | Baja (Limita etcd a nodos de control plane único coubicados, no para HA multi-master) |

---

## 3. Manifiestos y Configuraciones Completos y Sintácticamente Válidos

### 3.1 Manifiesto de Static Pod de etcd con Hardening para Producción
Ruta de Archivo: `/etc/kubernetes/manifests/etcd.yaml`

```yaml
apiVersion: v1
kind: Pod
metadata:
  annotations:
    kubeadm.kubernetes.io/etcd.advertise-hosts.endpoint: https://192.168.10.11:2379
  creationTimestamp: null
  labels:
    component: etcd
    tier: control-plane
  name: etcd-controlplane-01
  namespace: kube-system
spec:
  containers:
  - command:
    - etcd
    - --advertise-client-urls=https://192.168.10.11:2379
    - --cert-file=/etc/kubernetes/pki/etcd/server.crt
    - --client-cert-auth=true
    - --data-dir=/var/lib/etcd
    - --experimental-initial-corrupt-check=true
    - --experimental-watch-progress-notify-interval=5s
    - --initial-advertise-peer-urls=https://192.168.10.11:2380
    - --initial-cluster=controlplane-01=https://192.168.10.11:2380
    - --initial-cluster-state=new
    - --key-file=/etc/kubernetes/pki/etcd/server.key
    - --listen-client-urls=https://127.0.0.1:2379,https://192.168.10.11:2379
    - --listen-metrics-urls=https://127.0.0.1:2381
    - --listen-peer-urls=https://192.168.10.11:2380
    - --name=controlplane-01
    - --peer-cert-file=/etc/kubernetes/pki/etcd/peer.crt
    - --peer-client-cert-auth=true
    - --peer-key-file=/etc/kubernetes/pki/etcd/peer.key
    - --peer-trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
    - --peer-cipher-suites=TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
    - --cipher-suites=TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
    - --snapshot-count=10000
    - --trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
    image: registry.k8s.io/etcd:3.5.12-0
    imagePullPolicy: IfNotPresent
    livenessProbe:
      failureThreshold: 8
      httpGet:
        host: 127.0.0.1
        path: /livez
        port: 2381
        scheme: HTTPS
      initialDelaySeconds: 10
      periodSeconds: 10
      timeoutSeconds: 15
    readinessProbe:
      failureThreshold: 3
      httpGet:
        host: 127.0.0.1
        path: /readyz
        port: 2381
        scheme: HTTPS
      initialDelaySeconds: 5
      periodSeconds: 10
      timeoutSeconds: 5
    resources:
      requests:
        cpu: 100m
        memory: 100Mi
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop:
        - ALL
      readOnlyRootFilesystem: false
      runAsGroup: 0
      runAsNonRoot: false
      runAsUser: 0
    volumeMounts:
    - mountPath: /var/lib/etcd
      name: etcd-data
    - mountPath: /etc/kubernetes/pki/etcd
      name: etcd-certs
  hostNetwork: true
  priorityClassName: system-node-critical
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  volumes:
  - hostPath:
      path: /var/lib/etcd
      type: DirectoryOrCreate
    name: etcd-data
  - hostPath:
      path: /etc/kubernetes/pki/etcd
      type: DirectoryOrCreate
    name: etcd-certs
status: {}
```

---

### 3.2 Manifiesto de Configuración de Cifrado KMS v2
Ruta de Archivo: `/etc/kubernetes/enc/encryption-config.yaml`

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
          endpoint: unix:///var/run/kmsplugin/v2/vault.sock
          timeout: 3s
          cachesize: 1000
      - aescbc:
          keys:
            - name: fallback-key-v1
              secret: c2V2ZW50ZWVuLWJ5dGUtbG9uZy1zZWNyZXQtcGhhc2UtMQ==
      - identity: {}
```

---

### 3.3 Fragmento de Patch de kube-apiserver para Cifrado y mTLS de etcd
Ruta de Archivo: `/etc/kubernetes/manifests/kube-apiserver.yaml` (Extracto bajo `spec.containers[0].command`)

```yaml
spec:
  containers:
  - command:
    - kube-apiserver
    - --etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt
    - --etcd-certfile=/etc/kubernetes/pki/apiserver-etcd-client.crt
    - --etcd-keyfile=/etc/kubernetes/pki/apiserver-etcd-client.key
    - --etcd-servers=https://192.168.10.11:2379,https://192.168.10.12:2379,https://192.168.10.13:2379
    - --encryption-provider-config=/etc/kubernetes/enc/encryption-config.yaml
    volumeMounts:
    - mountPath: /etc/kubernetes/enc
      name: kms-enc-config
      readOnly: true
    - mountPath: /var/run/kmsplugin
      name: kms-sock
  volumes:
  - hostPath:
      path: /etc/kubernetes/enc
      type: DirectoryOrCreate
    name: kms-enc-config
  - hostPath:
      path: /var/run/kmsplugin
      type: DirectoryOrCreate
    name: kms-sock
```

---

## 4. Comandos CLI Reales y Salidas Esperadas

### 4.1 Verificación del Estado de Salud y Membresía del Cluster etcd Vía mTLS
Ejecutá `etcdctl` utilizando los certificados adecuados para consultar el estado del cluster a través de los endpoints.

```bash
$ export ETCDCTL_API=3
$ etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  --endpoints=https://192.168.10.11:2379,https://192.168.10.12:2379,https://192.168.10.13:2379 \
  endpoint health -w table
```

**Salida Esperada:**
```
+---------------------------+--------+-------------+-------+
|         ENDPOINT          | HEALTH |    TOOK     | ERROR |
+---------------------------+--------+-------------+-------+
| https://192.168.10.11:2379 |   true | 11.452441ms |       |
| https://192.168.10.12:2379 |   true | 12.110534ms |       |
| https://192.168.10.13:2379 |   true |  9.887213ms |       |
+---------------------------+--------+-------------+-------+
```

```bash
$ etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  --endpoints=https://192.168.10.11:2379 \
  member list -w table
```

**Salida Esperada:**
```
+------------------+---------+------------------+---------------------------+---------------------------+------------+
|        ID        | STATUS  |       NAME       |        PEER URLS          |       CLIENT URLS         | IS LEARNER |
+------------------+---------+------------------+---------------------------+---------------------------+------------+
| a3e78912b45012ef | started | controlplane-01  | https://192.168.10.11:2380 | https://192.168.10.11:2379 |      false |
| b4f89023c5612300 | started | controlplane-02  | https://192.168.10.12:2380 | https://192.168.10.12:2379 |      false |
| c5a90134d6723411 | started | controlplane-03  | https://192.168.10.13:2380 | https://192.168.10.13:2379 |      false |
+------------------+---------+------------------+---------------------------+---------------------------+------------+
```

---

### 4.2 Verificación del Cifrado de Secrets en Reposo en etcd

Primero, creá un Secret de prueba de destino mediante `kubectl`:

```bash
$ kubectl create secret generic db-credentials \
  --from-literal=username=admin \
  --from-literal=password=SuperSecretPass123! \
  -n default
```

**Salida Esperada:**
```
secret/db-credentials created
```

A continuación, leé la clave directamente desde etcd utilizando `etcdctl` para verificar que el valor esté cifrado en lugar de estar en texto plano.

```bash
$ etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  --endpoints=https://127.0.0.1:2379 \
  get /registry/secrets/default/db-credentials | head -n 3
```

**Salida Esperada (Cuando está cifrado con KMS v2):**
```
/registry/secrets/default/db-credentials
k8s:enc:kms:v2:vault-kms-provider:A%#1GV standard payload block...
```

**Salida Esperada (Cuando está cifrado con AES-CBC):**
```
/registry/secrets/default/db-credentials
k8s:enc:aescbc:v1:fallback-key-v1:"f+~}+~L
```

> **Nota de Seguridad:** Si la salida comienza con `{"kind":"Secret","apiVersion":"v1"`, el cifrado en reposo **NO está habilitado**, lo que representa una vulnerabilidad mayor en un entorno de producción.

---

### 4.3 Re-cifrado de Secrets Existentes Tras la Rotación de Claves
Actualizar la `EncryptionConfiguration` solo cifra las operaciones de escritura *nuevas* o *modificadas*. Los secrets existentes deben re-cifrarse in situ.

```bash
$ kubectl get secrets --all-namespaces -o json | kubectl replace -f -
```

**Salida Esperada:**
```
secret/bootstrap-token-abcdef replaced
secret/db-credentials replaced
secret/default-token-5x2pq replaced
...
```

Método automatizado alternativo utilizando la migración de almacenamiento estándar de Kubernetes:

```bash
$ kubectl storageversionmigrate --resources=secrets
```

---

### 4.4 Realización de un Backup de Snapshot Consistente

```bash
$ ETCDCTL_API=3 etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  --endpoints=https://127.0.0.1:2379 \
  snapshot save /var/lib/etcd-backups/etcd-snapshot-$(date +%Y%m%d%H%M%S).db
```

**Salida Esperada:**
```
Snapshot saved at /var/lib/etcd-backups/etcd-snapshot-20260807194000.db
Initializing raw snapshot format...
Snapshot real size: 14.2 MB
Snapshot total size: 14.2 MB
Snapshot status:
Hash: a891f7c2b531
Revision: 1045923
TotalKey: 8941
TotalSize: 14876672
```

---

## 5. Guía de Verificación y Resolución de Problemas

### 5.1 Escenario A: `x509: certificate signed by unknown authority` / Falla en Handshake mTLS

#### Síntoma
Los logs de `kube-apiserver` muestran caídas persistentes de conexión hacia etcd, y `etcdctl` falla con un error de handshake TLS:

```
Error: remote error: tls: bad certificate
```

#### Protocolo de Diagnóstico
1. Verificá las fechas de los certificados y períodos de validez en el nodo:
   ```bash
   $ openssl x509 -in /etc/kubernetes/pki/etcd/server.crt -text -noout | grep -A 2 "Validity"
   ```
2. Verificá que los Subject Alternative Names (SANs) incluyan la dirección IP o nombre de host de destino:
   ```bash
   $ openssl x509 -in /etc/kubernetes/pki/etcd/server.crt -text -noout | grep -A 1 "Subject Alternative Name"
   ```
3. Proba la conexión mTLS utilizando `openssl s_client`:
   ```bash
   $ openssl s_client -connect 192.168.10.11:2379 \
     -CAfile /etc/kubernetes/pki/etcd/ca.crt \
     -cert /etc/kubernetes/pki/etcd/server.crt \
     -key /etc/kubernetes/pki/etcd/server.key
   ```
   *Buscá `Verify return code: 0 (ok)`.*

#### Remediación
Si falta el SAN o el certificado expiró, regenerá los certificados de etcd utilizando `kubeadm`:
```bash
$ kubeadm certs renew etcd-server etcd-peer etcd-healthcheck-client
```

---

### 5.2 Escenario B: Falla en el Descifrado de Secrets Tras la Rotación de Claves

#### Síntoma
`kube-apiserver` retorna errores HTTP 500 al leer secrets:
```
Internal error occurred: error decoding stored object: cipher: message authentication failed
```

#### Protocolo de Diagnóstico
1. La clave de descifrado utilizada para codificar el secret ya no está presente bajo la lista `providers` en `/etc/kubernetes/enc/encryption-config.yaml`.
2. Recordá que los proveedores se evalúan **de arriba a abajo para lecturas**, pero **solo el primer proveedor se utiliza para escrituras**.
3. Inspeccioná los logs del pod `kube-apiserver`:
   ```bash
   $ kubectl logs -n kube-system kube-apiserver-controlplane-01 | grep -i "encryption"
   ```

#### Remediación
Restaurá la clave de descifrado anterior como una entrada secundaria de proveedor en `encryption-config.yaml` para permitir la lectura de secrets más antiguos, luego activá un ciclo de re-cifrado de secrets a nivel de todo el cluster:

```yaml
resources:
  - resources:
      - secrets
    providers:
      - kms:
          apiVersion: v2
          name: vault-kms-provider
          endpoint: unix:///var/run/kmsplugin/v2/vault.sock
      - aescbc:
          keys:
            - name: old-key-v0 # Restored for legacy read capability
              secret:T2xkS2V5VmFsdWUxMjM0NTY3ODkwMTIzNDU2Nw==
```

---

### 5.3 Escenario C: Pérdida de Quórum y Recuperación de Split-Brain

#### Síntoma
El endpoint de etcd responde con `etcdserver: request timed out` o `raft: cannot lead with stale member`.

#### Protocolo de Diagnóstico
1. Verificá el estado de los miembros para identificar el ID del nodo muerto o no responsivo:
   ```bash
   $ etcdctl --endpoints=https://127.0.0.1:2379 member list
   ```
2. Si fallan 2 nodos de un cluster de 3 nodos, el quórum se pierde permanentemente ($1 < 2$).
3. Remové el nodo muerto del consenso Raft si la mayoría aún existe:
   ```bash
   $ etcdctl --endpoints=https://127.0.0.1:2379 member remove <unhealthy-member-id>
   ```

#### Protocolo de Recuperación Ante Desastres de Emergencia (Restauración Forzada de Un Solo Nodo)
Si el quórum se pierde por completo y no se puede recuperar:
1. Detené todos los Static Pods de `etcd` en todos los nodos del control plane moviendo `/etc/kubernetes/manifests/etcd.yaml` fuera del directorio.
2. Restaurá el snapshot más reciente en un solo nodo master con `--skip-hash-check`:
   ```bash
   $ etcdctl snapshot restore /var/lib/etcd-backups/etcd-snapshot-latest.db \
     --name=controlplane-01 \
     --initial-cluster=controlplane-01=https://192.168.10.11:2380 \
     --initial-advertise-peer-urls=https://192.168.10.11:2380 \
     --data-dir=/var/lib/etcd-restored
   ```
3. Actualizá la ruta del host path del volumen en `/etc/kubernetes/manifests/etcd.yaml` para que apunte a `/var/lib/etcd-restored`.
4. Mové `etcd.yaml` nuevamente a `/etc/kubernetes/manifests/` para reiniciar el cluster de un solo nodo.

---

## 6. Referencias

* **CNCF KCSA Curriculum:**
  https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
* **Kubernetes Official Documentation – Encrypting Secret Data at Rest:**
  https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
* **Kubernetes Official Documentation – KMS v2 Provider Setup:**
  https://kubernetes.io/docs/tasks/administer-cluster/kms-provider/
* **etcd Official Security & Hardening Guide:**
  https://etcd.io/docs/v3.5/op-guide/security/
* **etcd Official Clustering & Disaster Recovery Guide:**
  https://etcd.io/docs/v3.5/op-guide/clustering/