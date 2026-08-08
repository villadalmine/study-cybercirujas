# CNCF KCSA (Kubernetes & Cloud Native Security Associate)
## Tema 2.8: Seguridad, arquitectura y operaciones de Etcd

---

### Documentación oficial de referencia
- [Kubernetes Documentation: Operating etcd clusters for Kubernetes](https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/)
- [Kubernetes Documentation: Encrypting Secret Data at Rest](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/)
- [Etcd Official Security Guide](https://etcd.io/docs/v3.5/op-guide/security/)
- [Etcd Disaster Recovery Guide](https://etcd.io/docs/v3.5/op-guide/recovery/)
- [CNCF KCSA Curriculum](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)

---

### Visión general arquitectónica en detalle: Etcd en Kubernetes

Etcd es un almacén de clave-valor distribuido y fuertemente consistente que implementa el **Raft Consensus Algorithm**. En Kubernetes, etcd funciona como la única fuente de verdad (single source of truth) para todo el estado del cluster, metadatos de objetos y secretos de configuración. 

#### Almacenamiento interno y motor MVCC
- **Control de concurrencia multiversión (MVCC):** Etcd no sobrescribe los pares clave-valor existentes en el lugar. En su lugar, cada mutación (escritura, actualización, eliminación) crea una nueva revisión que incrementa el contador global de revisiones del cluster de 64 bits. Una sola clave lógica (por ejemplo, `/registry/secrets/default/app-db-pass`) mantiene múltiples revisiones históricas hasta que ocurre una compactación explícita de la base de datos.
- **Motor de almacenamiento subyacente:** Etcd v3 utiliza **bbolt** (una base de datos de clave-valor ACID embebida escrita en Go) para almacenar páginas mapeadas en memoria en el disco. Las claves se almacenan como índices b-tree que mapean claves lógicas a revisiones de generación, mientras que los valores se almacenan en un árbol B+ indexado por números de revisión.
- **Registro de escritura adelantada (WAL):** Antes de que cualquier transacción se confirme en el motor de almacenamiento bbolt, se escribe en el archivo WAL y se sincroniza con el almacenamiento físico (`fsync`). Raft garantiza que si una mayoría (quórum: $\lfloor N/2 \rfloor + 1$) de los nodos añade con éxito la entrada a su WAL local, la transacción queda confirmada.

#### Arquitectura de red y límites de seguridad
Etcd expone dos endpoints de red distintos:
1. **Puerto de comunicación entre pares (Peer Communication Port, predeterminado `2380`):** Utilizado exclusivamente para el IPC de consenso Raft entre nodos etcd (elección de líder, replicación de logs, tramas de heartbeat).
2. **Puerto de comunicación con clientes (Client Communication Port, predeterminado `2379`):** Utilizado por `kube-apiserver` y herramientas CLI (`etcdctl`) para transacciones de lectura/escritura gRPC.

```
       +-------------------------------------------------------------+
       |               Control Plane Node (IP: 10.0.1.10)            |
       |                                                             |
       |  +--------------------+             +--------------------+  |
       |  |  kube-apiserver    | -- mTLS --> |     etcd Server    |  |
       |  |                    |  Port 2379  |                    |  |
       |  +--------------------+             +--------------------+  |
       |                                                ^            |
       +------------------------------------------------|------------+
                                                        |
                                            mTLS (Raft Consensus)
                                            Port 2380
                                                        |
       +------------------------------------------------|------------+
       |               Control Plane Node (IP: 10.0.1.11) v          |
       |  +--------------------+             +--------------------+  |
       |  |  kube-apiserver    | -- mTLS --> |     etcd Server    |  |
       |  |                    |  Port 2379  |                    |  |
       |  +--------------------+             +--------------------+  |
       +-------------------------------------------------------------+
```

---

### Módulo 1: TLS mutuo (mTLS) de PKI y verificación del estado de salud del cluster

Debido a que poseer acceso de cliente a etcd permite la mutación arbitraria del estado—incluyendo omitir los Admission Controllers del API server, las reglas de RBAC y Audit Logging—asegurar etcd con TLS mutuo (mTLS) X.509 estricto es obligatorio.

#### Ejecución práctica guiada

1. Conéctese por SSH al nodo del control plane y verifique los parámetros del manifiesto del pod estático que rigen la seguridad de transporte de etcd ubicados en `/etc/kubernetes/manifests/etcd.yaml`.

```bash
sudo cat /etc/kubernetes/manifests/etcd.yaml | grep -E '\--(cert-file|key-file|trusted-ca-file|client-cert-auth|peer-cert-file|peer-key-file|peer-trusted-ca-file|peer-client-cert-auth)'
```

**Salida esperada del comando:**
```text
    - --cert-file=/etc/kubernetes/pki/etcd/server.crt
    - --client-cert-auth=true
    - --key-file=/etc/kubernetes/pki/etcd/server.key
    - --peer-cert-file=/etc/kubernetes/pki/etcd/peer.crt
    - --peer-client-cert-auth=true
    - --peer-key-file=/etc/kubernetes/pki/etcd/peer.key
    - --peer-trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
    - --trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
```

2. Inspeccione el certificado de servidor X.509 para verificar que los Nombres Alternativos del Sujeto (SANs) coincidan con el loopback local del control plane y la IP interna del nodo.

```bash
sudo openssl x509 -in /etc/kubernetes/pki/etcd/server.crt -text -noout | grep -A 2 "Subject Alternative Name"
```

**Salida esperada del comando:**
```text
            X509v3 Subject Alternative Name: 
                DNS:localhost, DNS:cp-node-01, IP Address:127.0.0.1, IP Address:10.0.1.10, IP Address:0:0:0:0:0:0:0:1
```

3. Configure las variables de entorno para `etcdctl` utilizando la versión 3 de la API y ejecute verificaciones de estado de salud contra el endpoint local.

```bash
export ETCDCTL_API=3
sudo etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health --write-out=table
```

**Salida esperada del comando:**
```text
+------------------------+--------+-------------+-------+
|        ENDPOINT        | HEALTH |    TOOK     | ERROR |
+------------------------+--------+-------------+-------+
| https://127.0.0.1:2379 |   true |  8.41243ms  |       |
+------------------------+--------+-------------+-------+
```

4. Recupere la topología detallada de miembros de etcd y verifique el estado de la elección de líder en todos los endpoints.

```bash
sudo etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list --write-out=table
```

**Salida esperada del comando:**
```text
+------------------+---------+------------+------------------------+------------------------+------------+
|        ID        | STATUS  |    NAME    |       PEER URLS        |      CLIENT URLS       | IS LEARNER |
+------------------+---------+------------+------------------------+------------------------+------------+
| 8e9e05c52164694d | started | cp-node-01 | https://10.0.1.10:2380 | https://10.0.1.10:2379 |      false |
+------------------+---------+------------+------------------------+------------------------+------------+
```

#### Preguntas de verificación y comprensión

- **Pregunta 1.1:** ¿Cuál es la consecuencia precisa de seguridad de establecer `--client-cert-auth=false` en una instancia de etcd expuesta en la IP `0.0.0.0:2379` dentro de una VPC en la nube?
- **Pregunta 1.2:** ¿Por qué etcd mantiene dos configuraciones de Autoridad Certificadora (CA) o pares de certificados completamente separados para las comunicaciones de par a par (`--peer-cert-file`) y cliente a servidor (`--cert-file`) en topologías HA de producción?

---

### Módulo 2: Cifrado en reposo de Kubernetes (Integración de KMS v2 y AES-GCM)

Por defecto, Kubernetes escribe objetos en etcd en formato JSON/Protocol Buffers serializado en UTF-8 sin cifrar. Cualquiera con acceso de lectura al volumen de almacenamiento subyacente (`/var/lib/etcd`) o acceso de cliente al puerto `2379` puede extraer datos de Secret con altos privilegios, incluyendo tokens de ServiceAccount y credenciales de base de datos.

#### Mecánica arquitectónica del cifrado sobre (Envelope Encryption - KMS v2)
1. **Generación de DEK:** El `kube-apiserver` genera una clave de cifrado de datos (Data Encryption Key - DEK) aleatoria localmente utilizando AES-GCM o AES-CBC.
2. **Cifrado de datos:** El `kube-apiserver` cifra el recurso de Kubernetes en texto plano (por ejemplo, un Secret) utilizando la DEK.
3. **Cifrado de clave (Envelope):** El `kube-apiserver` llama a un plugin de KMS externo (HashiCorp Vault, AWS KMS, GCP KMS, Azure Key Vault) a través de un UNIX Domain Socket gRPC para cifrar la DEK local utilizando una clave maestra de cifrado de claves (Key Encryption Key - KEK).
4. **Almacenamiento:** La carga útil cifrada del objeto junto con los metadatos de la DEK cifrada se almacena en etcd.

```
                  +---------------------------------------------------+
                  |                 kube-apiserver                    |
                  |                                                   |
                  |  Plaintext Secret                                 |
                  |         |                                         |
                  |         v                                         |
                  |  +--------------+  Encrypts Data   +-----------+  |
                  |  |  AES-GCM     | <--------------  | Random    |  |
                  |  |  Ciphertext  |                  | DEK       |  |
                  |  +--------------+                  +-----------+  |
                  |         |                                |        |
                  +---------|--------------------------------|--------+
                            |                                |
                            |                        gRPC (UNIX Socket)
                            |                                v
                            |                          +-----------+
                            |                          | KMS Plugin| (Encrypts DEK with KEK)
                            |                          +-----------+
                            |                                |
                            v                                v
                  +---------------------------------------------------+
                  |           Combined Payload in etcd                |
                  |  [ Encrypted DEK Header ] + [ Encrypted Payload ] |
                  +---------------------------------------------------+
```

#### Ejecución práctica guiada

1. Cree un manifiesto `EncryptionConfiguration` completo y sintácticamente válido en `/etc/kubernetes/enc/encryption-config.yaml` utilizando el proveedor `aescbc` y una clave secreta segura de 32 bytes codificada en base64.

Genere 32 bytes aleatorios codificados en base64:
```bash
head -c 32 /dev/urandom | base64
```
*Clave de salida de muestra: `k9X8jZ2L1pQ4vR7mS3tU5wX8yZ1aB3cD5eF7gH9iJ0k=`*

2. Construya el archivo de configuración:

```yaml
# File path: /etc/kubernetes/enc/encryption-config.yaml
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
              secret: k9X8jZ2L1pQ4vR7mS3tU5wX8yZ1aB3cD5eF7gH9iJ0k=
      - identity: {}
```

3. Modifique `/etc/kubernetes/manifests/kube-apiserver.yaml` para habilitar el proveedor de cifrado y montar el directorio de configuración.

Añada la siguiente flag a los argumentos del contenedor `kube-apiserver`:
```yaml
    - --encryption-provider-config=/etc/kubernetes/enc/encryption-config.yaml
```

Añada los volúmenes hostPath y volumeMounts:
```yaml
  volumeMounts:
  - mountPath: /etc/kubernetes/enc
    name: enc-config
    readOnly: true
  volumes:
  - name: enc-config
    hostPath:
      path: /etc/kubernetes/enc
      type: DirectoryOrCreate
```

4. Cree un secret de prueba en el namespace `default`.

```bash
kubectl create secret generic production-db-creds \
  --from-literal=username='postgres_admin' \
  --from-literal=password='SuperSecretPass2026!' \
  --namespace=default
```

**Salida esperada del comando:**
```text
secret/production-db-creds created
```

5. Lea el flujo de bytes sin procesar almacenado directamente desde etcd utilizando `etcdctl` para verificar que la carga útil esté cifrada en reposo y contenga el prefijo de encabezado de clave `k8s:enc:aescbc:v1:key1`.

```bash
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/default/production-db-creds
```

**Salida esperada del comando:**
```text
/registry/secrets/default/production-db-creds
k8s:enc:aescbc:v1:key1:%` =|U|+G-q^.?C#]0;{~,%#x!+\[4.[r+!L standard-output...
```

6. Verifique que los Secrets existentes creados antes de aplicar la configuración se puedan migrar a un estado cifrado usando `kubectl`.

```bash
kubectl get secrets --all-namespaces -o json | kubectl replace -f -
```

**Salida esperada del comando:**
```text
secret/production-db-creds replaced
secret/sh.helm.release.v1.ingress-nginx.v1 replaced
...
```

#### Preguntas de verificación y comprensión

- **Pregunta 2.1:** En un archivo `EncryptionConfiguration` que contiene múltiples proveedores en la lista, ¿qué regla rige cómo el `kube-apiserver` procesa las transacciones de lectura versus las transacciones de escritura?
- **Pregunta 2.2:** Durante un procedimiento de rotación de claves de cifrado, ¿por qué la nueva clave de cifrado debe posicionarse en la parte superior de la lista de proveedores mientras se mantiene la clave de cifrado antigua inmediatamente debajo de ella?

---

### Módulo 3: Autenticación nativa de Etcd, RBAC y Firewalling de red del Host

Si bien Kubernetes gestiona el control de acceso a través de RBAC en `kube-apiserver`, el propio etcd tiene un sistema integrado de autenticación y control de acceso basado en roles (RBAC) para solicitudes gRPC. Además, el aislamiento a nivel de red mediante `iptables` / firewalls de Linux evita que nodos no autorizados se conecten a los puertos `2379` y `2380`.

#### Ejecución práctica guiada

1. Inspeccione las reglas del firewall de la red del host (`iptables`) para asegurarse de que el puerto 2379 esté strictly restringido a conexiones entrantes originadas desde IPs autorizadas de `kube-apiserver`.

```bash
sudo iptables -L INPUT -v -n | grep -E '(2379|2380)'
```

**Salida esperada del comando (Configuración estándar de firewall seguro):**
```text
    0     0 ACCEPT     tcp  --  *      *       10.0.1.10            0.0.0.0/0            tcp dpt:2379 /* Allow API Server access to etcd */
    0     0 ACCEPT     tcp  --  *      *       10.0.1.11            0.0.0.0/0            tcp dpt:2379 /* Allow API Server access to etcd */
    0     0 DROP       tcp  --  *      *       0.0.0.0/0            0.0.0.0/0            tcp dpt:2379 /* Drop unauthorized etcd client traffic */
```

2. Habilite la autenticación nativa de etcd y pruebe la creación de un usuario administrativo root junto con un rol restringido para aplicaciones de monitoreo (por ejemplo, Prometheus etcd-exporter).

```bash
# Create root user
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  user add root --interactive=false <<< "ComplexRootPass2026!"

# Enable Auth
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  auth enable
```

**Salida esperada del comando:**
```text
User root created
Authentication Enabled
```

3. Cree un rol restringido de solo lectura llamado `metrics-reader` que garantice acceso únicamente a los prefijos de clave `/health` y `/metrics`, asígnelo a un usuario y verifique la denegación de acceso en `/registry`.

```bash
# Create role
sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 --user=root:ComplexRootPass2026! role add metrics-reader

# Grant permission to read key range
sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 --user=root:ComplexRootPass2026! role grant-permission metrics-reader read --prefix /metrics

# Create user and assign role
sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 --user=root:ComplexRootPass2026! user add metrics-user --interactive=false <<< "MetricsPass2026!"
sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 --user=root:ComplexRootPass2026! user grant-role metrics-user metrics-reader
```

4. Intente consultar `/registry/secrets` utilizando la identidad `metrics-user`.

```bash
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --user=metrics-user:MetricsPass2026! \
  get /registry/secrets/default/production-db-creds
```

**Salida esperada del comando:**
```text
Error: etcdserver: permission denied
```

#### Preguntas de verificación y comprensión

- **Pregunta 3.1:** ¿Por qué un Kubernetes estándar desplegado con `kubeadm` se basa principalmente en la coincidencia CN/OU de certificados de cliente mTLS (`--client-cert-auth=true`) en lugar de RBAC con usuario/contraseña de etcd para autenticar el API server?
- **Pregunta 3.2:** Si un atacante obtiene acceso de red al puerto 2380 (el puerto entre pares de Raft) en un miembro del cluster etcd sin autenticación de pares mTLS aplicada (`--peer-client-cert-auth=false`), ¿qué vector de ataque específico se vuelve posible?

---

### Módulo 4: Recuperación ante desastres, capturas de pantalla de base de datos (Snapshots) y verificación de integridad

En un escenario de falla catastrófica del control plane o ransomware, los SRE deben restaurar el estado del cluster desde una captura de pantalla (snapshot) de etcd en un punto en el tiempo (Point-in-Time, PiT) verificada y no corrompida.

#### Ejecución práctica guiada

1. Genere una captura de pantalla (snapshot) consistente de la base de datos utilizando `etcdctl snapshot save`.

```bash
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /var/lib/etcd-backup/etcd-snapshot-$(date +%Y%m%d-%H%M%S).db
```

**Salida esperada del comando:**
```text
Snapshot saved at /var/lib/etcd-backup/etcd-snapshot-20260807-194500.db
```

2. Valide la integridad, suma de verificación (hash sum), total de claves y recuento de revisiones de la captura de pantalla (snapshot) generada.

```bash
sudo ETCDCTL_API=3 etcdctl \
  --write-out=table \
  snapshot status /var/lib/etcd-backup/etcd-snapshot-20260807-194500.db
```

**Salida esperada del comando:**
```text
+----------+----------+------------+------------+
|   HASH   | REVISION | TOTAL KEYS | TOTAL SIZE |
+----------+----------+------------+------------+
| c4e8b9a1 |    45912 |       3210 |     4.2 MB |
+----------+----------+------------+------------+
```

3. Simule un procedimiento de recuperación ante desastres del cluster restaurando el snapshot en un directorio de datos aislado `/var/lib/etcd-restored`.

```bash
sudo ETCDCTL_API=3 etcdctl \
  snapshot restore /var/lib/etcd-backup/etcd-snapshot-20260807-194500.db \
  --data-dir=/var/lib/etcd-restored \
  --name=cp-node-01 \
  --initial-cluster=cp-node-01=https://10.0.1.10:2380 \
  --initial-cluster-token=etcd-cluster-token-1 \
  --initial-advertise-peer-urls=https://10.0.1.10:2380
```

**Salida esperada del comando:**
```text
2026-08-07T19:46:12Z	INFO	snapshot/v3_snapshot.go:309	restoring snapshot	{"path": "/var/lib/etcd-backup/etcd-snapshot-20260807-194500.db", "wal-dir": "/var/lib/etcd-restored/member/wal", "data-dir": "/var/lib/etcd-restored", "default-backend-freelist-type": "map"}
2026-08-07T19:46:12Z	INFO	snapshot/v3_snapshot.go:336	successfully restored snapshot to "/var/lib/etcd-restored"
```

4. Actualice el volumen hostPath en `/etc/kubernetes/manifests/etcd.yaml` para cambiar el puntero de la base de datos activa de `/var/lib/etcd` a `/var/lib/etcd-restored`.

```yaml
  volumes:
  - name: etcd-data
    hostPath:
      path: /var/lib/etcd-restored
      type: DirectoryOrCreate
```

5. Monitoree los logs de Kubelet para confirmar que el pod de etcd se reinicie correctamente y que `kube-apiserver` se reconecte.

```bash
sudo crictl logs $(sudo crictl ps --name=etcd -q) 2>&1 | tail -n 10
```

**Salida esperada del comando:**
```text
2026-08-07T19:47:05.123Z INFO ready to serve client requests
2026-08-07T19:47:05.125Z INFO serving client requests requests on 127.0.0.1:2379
2026-08-07T19:47:05.125Z INFO serving client requests requests on 10.0.1.10:2379
```

#### Preguntas de verificación y comprensión

- **Pregunta 4.1:** ¿Por qué es imperativo pasar `--initial-cluster-token` y un `--initial-advertise-peer-urls` explícito al ejecutar `etcdctl snapshot restore` en un control plane de alta disponibilidad (HA) de múltiples nodos?
- **Pregunta 4.2:** ¿Qué problema operativo ocurre si `etcdctl snapshot restore` se ejecuta mientras el contenedor del pod estático `etcd` está ejecutándose activamente y escribiendo en `/var/lib/etcd`?

---

<details>
<summary><b>Respuestas y explicaciones</b></summary>

### Respuestas del Módulo 1

- **Respuesta 1.1:** Establecer `--client-cert-auth=false` deshabilita la validación del certificado cliente X.509 en el puerto 2379. Si etcd está escuchando en una interfaz de red pública o sin firewall (`0.0.0.0`), cualquier atacante de red no autenticado puede emitir solicitudes API gRPC para leer todos los secretos del cluster, eludir completamente el RBAC de Kubernetes, modificar el estado del cluster, crear pods privilegiados o borrar el estado completo de la base de datos.
- **Respuesta 1.2:** La comunicación entre pares (puerto 2380) maneja las operaciones de consenso Raft entre los miembros del cluster, mientras que la comunicación con el cliente (puerto 2379) atiende a los consumidores de la API (`kube-apiserver`). El uso de CA separadas o pares de certificados distintos aísla los dominios de seguridad: las credenciales de cliente del API server comprometidas no se pueden utilizar indebidamente para unirse como un nodo etcd malicioso al grupo de pares de Raft, y viceversa.

---

### Respuestas del Módulo 2

- **Respuesta 2.1:** Los proveedores listados en `EncryptionConfiguration` se evalúan en orden secuencial de arriba a abajo:
  - **Operaciones de escritura:** El `kube-apiserver` utiliza estrictamente el **primer** proveedor de la lista para cifrar objetos nuevos o modificados.
  - **Operaciones de lectura:** El `kube-apiserver` intenta descifrar objetos utilizando cada proveedor secuencialmente de arriba a abajo hasta que uno descifra con éxito la carga útil. Si ninguno tiene éxito (o si se lee un objeto no cifrado cuando `identity` no está presente), la lectura falla.
- **Respuesta 2.2:** Colocar la nueva clave en la parte superior de la lista de proveedores garantiza que todas las operaciones de escritura posteriores cifren los datos utilizando la nueva clave. Conservar la clave antigua inmediatamente debajo permite que el `kube-apiserver` lea perfectamente los objetos existentes cifrados con la clave antigua durante la fase de transición. Ejecutar `kubectl get secrets --all-namespaces -o json | kubectl replace -f -` vuelve a escribir todos los secretos existentes, cifrándolos con la clave superior (nueva), después de lo cual la clave antigua se puede eliminar de forma segura.

---

### Respuestas del Módulo 3

- **Respuesta 3.1:** Kubernetes se basa principalmente en la autenticación de certificados de cliente mTLS (`--client-cert-auth=true`) porque la verificación de identidad basada en certificados se integra directamente en la infraestructura PKI gestionada por `kubeadm` o aprovisionadores de control plane personalizados. El SAN/CN del certificado de cliente autentica de manera única al `kube-apiserver` a través de canales TLS cifrados sin almacenar credenciales estáticas en texto plano ni necesitar bases de datos de usuarios con estado dentro de etcd antes del arranque (bootstrapping).
- **Respuesta 3.2:** Si se puede acceder al puerto 2380 sin autenticación de pares mTLS aplicada (`--peer-client-cert-auth=false`), un atacante puede conectar una instancia de etcd maliciosa a la topología del cluster Raft, desencadenar una interrupción en la elección de Raft, transmitir actualizaciones completas de replicación del log WAL que contengan todas las entradas de la base de datos o inyectar entradas WAL maliciosas para corromper el consenso del cluster.

---

### Respuestas del Módulo 4

- **Respuesta 4.1:** Restaurar una captura de pantalla (snapshot) crea una nueva identidad de membresía lógica del cluster Raft. Proporcionar parámetros explícitos `--initial-cluster-token`, `--name` e `--initial-advertise-peer-urls` evita que los miembros restaurados intenten comunicarse con miembros del cluster preexistentes en ejecución utilizando IDs de cluster desactualizados, lo que evita condiciones de cerebro dividido (split-brain) de Raft y pánicos por desajuste de ID de snapshot.
- **Respuesta 4.2:** Restaurar una captura de pantalla (snapshot) en un directorio de datos activo (`/var/lib/etcd`) mientras etcd se está ejecutando causa bloqueos de descriptores de archivo e inconsistencias de estado entre las páginas de bbolt mapeadas en memoria y los logs WAL subyacentes. Esto da como resultado la corrupción de la base de datos, pánicos en la aplicación y bloqueos irrecuperables de la base de datos. El proceso de etcd (o pod estático) se debe detener antes de la restauración del directorio.

</details>