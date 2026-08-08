# Tema 2.11: Storage — Ejercicios guiados (KCSA)

> **Enfoque de seguridad.** En el dominio *Kubernetes Cluster Component Security* del KCSA, "Storage" no es cómo aprovisionar un volumen, sino **cómo un volumen se convierte en un vector de compromiso**: Secrets sin cifrar en etcd, `hostPath` como puerta al nodo, permisos de archivo laxos, y RBAC que permite montar rutas arbitrarias del host. Estos ejercicios recorren esos vectores y sus mitigaciones.
>
> **Prerrequisitos.** Un cluster de laboratorio donde tengas acceso a los nodos del control plane (kind, minikube o un cluster propio). Necesitás `kubectl`, y para el Ejercicio 1, acceso a `etcdctl` en el nodo del control plane. **Nunca ejecutes estos ejercicios contra un cluster de producción.**

---

## Ejercicio 1 — Encryption at rest: por qué un Secret NO está cifrado por defecto

El error conceptual más común de KCSA: creer que un `Secret` está cifrado. Por defecto solo está **codificado en base64**, y se guarda en **etcd en texto plano**. Cualquiera con acceso al backend de etcd (o a un backup de etcd) lee todos los Secrets del cluster.

**Pasos:**

1. Creá un Secret de prueba:

   ```bash
   kubectl create secret generic demo-cred \
     --from-literal=password='S3cr3t-KCSA!' -n default
   ```

   Salida esperada:
   ```
   secret/demo-cred created
   ```

2. Confirmá que base64 **no es cifrado** — se decodifica trivialmente:

   ```bash
   kubectl get secret demo-cred -n default -o jsonpath='{.data.password}' | base64 -d; echo
   ```

   Salida esperada:
   ```
   S3cr3t-KCSA!
   ```

3. Leé la clave **directamente desde etcd**, saltándote la API. En un cluster con etcd sin cifrado en reposo:

   ```bash
   ETCDCTL_API=3 etcdctl \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     get /registry/secrets/default/demo-cred | hexdump -C | head
   ```

   Salida esperada (fijate que el valor aparece **legible**):
   ```
   00000000  2f 72 65 67 69 73 74 72  79 2f 73 65 63 72 65 74  |/registry/secret|
   ...
   000000a0  53 33 63 72 33 74 2d 4b  43 53 41 21 0a ...        |S3cr3t-KCSA!.|
   ```

4. Ahora activá **Encryption at Rest**. En el nodo del control plane creá `/etc/kubernetes/enc/enc.yaml`:

   ```yaml
   apiVersion: apiserver.config.k8s.io/v1
   kind: EncryptionConfiguration
   resources:
     - resources:
         - secrets
       providers:
         # El PRIMER provider se usa para ESCRIBIR. Ponemos aescbc primero
         # para empezar a cifrar. identity queda al final para poder LEER
         # los Secrets viejos que todavía están en texto plano.
         - aescbc:
             keys:
               - name: key1
                 # 32 bytes en base64. Generar con:
                 # head -c 32 /dev/urandom | base64
                 secret: c2VjcmV0LWlzLTMyLWJ5dGVzLWxvbmctZm9yLWFlcw==
         - identity: {}
   ```

5. Referenciá el archivo en el manifiesto estático del apiserver (`/etc/kubernetes/manifests/kube-apiserver.yaml`), agregando el flag y montando el directorio:

   ```yaml
   spec:
     containers:
       - command:
           - kube-apiserver
           - --encryption-provider-config=/etc/kubernetes/enc/enc.yaml
           # ...resto de flags
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

   El kubelet reinicia el apiserver automáticamente al detectar el cambio del manifiesto estático.

6. **Re-cifrá los Secrets existentes.** El cambio solo cifra en las próximas escrituras; los viejos siguen en texto plano hasta reescribirse:

   ```bash
   kubectl get secrets --all-namespaces -o json | kubectl replace -f -
   ```

7. Repetí el paso 3. Ahora el prefijo delata el cifrado:

   ```
   000000a0  6b 38 73 3a 65 6e 63 3a  61 65 73 63 62 63 3a 76  |k8s:enc:aescbc:v|
   000000b0  31 3a 6b 65 79 31 3a ...                          |1:key1:...|
   ```

   El `S3cr3t-KCSA!` ya no aparece.

**Preguntas de comprensión:**

- **P1.1** — ¿Por qué se dice que un Secret "no está cifrado" si `kubectl` lo muestra como un blob ilegible?
- **P1.2** — En el `EncryptionConfiguration`, ¿qué pasaría si pusieras `identity: {}` **antes** de `aescbc`? ¿Los Secrets nuevos quedarían cifrados?
- **P1.3** — ¿Por qué es imprescindible el paso 6 (`kubectl replace`)? ¿Qué Secrets seguirían expuestos si lo omitieras?
- **P1.4** — Para producción, ¿por qué el KCSA recomienda un provider **KMS v2** en lugar de `aescbc` con la clave escrita en el archivo de configuración?

---

## Ejercicio 2 — `hostPath`: el volumen que rompe el aislamiento del nodo

`hostPath` monta una ruta del **sistema de archivos del nodo** dentro del Pod. Es el vector clásico de escape de contenedor: montá `/`, o el socket del runtime, y sos root en el nodo.

**Pasos:**

1. Creá un Pod que monta la raíz del host en modo lectura:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: host-snoop
     namespace: default
   spec:
     containers:
       - name: shell
         image: busybox:1.36
         command: ["sleep", "3600"]
         volumeMounts:
           - name: host-root
             mountPath: /host
             readOnly: true
     volumes:
       - name: host-root
         hostPath:
           path: /
           type: Directory
   ```

   ```bash
   kubectl apply -f host-snoop.yaml
   ```

2. Leé desde el Pod credenciales que viven en el nodo:

   ```bash
   kubectl exec host-snoop -- cat /host/etc/kubernetes/kubelet.conf | head
   ```

   Salida esperada (fragmento): el kubeconfig del kubelet, con datos suficientes para hablar con la API como ese nodo. Con `/var/lib/kubelet/pki/` accesible, el atacante roba la identidad del kubelet.

3. Verificá el riesgo del socket del runtime (aún más grave — equivale a root en el nodo):

   ```bash
   kubectl exec host-snoop -- ls -l /host/run/containerd/containerd.sock
   ```

4. Ahora **bloqueá** este patrón con **Pod Security Admission**. `hostPath` está prohibido en el perfil **Baseline**. Etiquetá el namespace:

   ```bash
   kubectl label namespace default \
     pod-security.kubernetes.io/enforce=baseline \
     pod-security.kubernetes.io/enforce-version=latest --overwrite
   ```

5. Borrá y reintentá crear el Pod:

   ```bash
   kubectl delete pod host-snoop
   kubectl apply -f host-snoop.yaml
   ```

   Salida esperada (rechazo del admission controller):
   ```
   Error from server (Forbidden): error when creating "host-snoop.yaml":
   pods "host-snoop" is forbidden: violates PodSecurity "baseline:latest":
   hostPath volumes (volume "host-root")
   ```

**Preguntas de comprensión:**

- **P2.1** — El Pod montó `/host` como `readOnly: true`. ¿Eso lo hace seguro? Justificá con lo que leíste en el paso 2.
- **P2.2** — ¿Qué diferencia hay, en términos de superficie de ataque, entre montar `/host/etc/kubernetes/kubelet.conf` y montar `/host/run/containerd/containerd.sock`?
- **P2.3** — Pod Security Admission actuó en el momento de la creación. ¿Qué controlás con `enforce` vs. `warn` vs. `audit`, y por qué querrías los tres etiquetados a la vez durante una migración?
- **P2.4** — Baseline prohíbe `hostPath`, pero un Pod legítimo (por ejemplo un agente de logging que debe leer `/var/log`) lo necesita. ¿Cuál es la vía correcta para permitirlo sin abrir el Baseline de todo el namespace?

---

## Ejercicio 3 — Permisos de volúmenes: `fsGroup`, `readOnlyRootFilesystem` y `defaultMode`

Montar un volumen de forma segura no termina en el tipo de volumen: importa **quién puede leerlo dentro del Pod** y **si el proceso puede escribir su propio filesystem**.

**Pasos:**

1. Creá un Pod sin endurecer que monta un Secret y corre como root:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: vol-perms
     namespace: default
   spec:
     containers:
       - name: app
         image: busybox:1.36
         command: ["sleep", "3600"]
         volumeMounts:
           - name: cred
             mountPath: /etc/cred
             readOnly: true
     volumes:
       - name: cred
         secret:
           secretName: demo-cred
   ```
   *(Si activaste Baseline en el Ej. 2, este Pod se acepta: no usa `hostPath`.)*

2. Inspeccioná los permisos por defecto del archivo del Secret:

   ```bash
   kubectl exec vol-perms -- ls -l /etc/cred/
   kubectl exec vol-perms -- id
   ```

   Salida esperada:
   ```
   -rw-r--r--    1 root     root  ...  password
   uid=0(root) gid=0(root) groups=0(root)
   ```

   El archivo es **0644**: cualquier usuario dentro del contenedor lo lee, y el proceso corre como **root**.

3. Verificá que el volumen del Secret vive en **tmpfs** (memoria), no en el disco del nodo — mitigación que Kubernetes aplica solo:

   ```bash
   kubectl exec vol-perms -- mount | grep /etc/cred
   ```

   Salida esperada:
   ```
   tmpfs on /etc/cred type tmpfs (ro,relatime,...)
   ```

4. Endurecé el Pod: usuario no-root, `fsGroup`, permisos restrictivos del Secret y filesystem raíz de solo lectura:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: vol-perms-hardened
     namespace: default
   spec:
     securityContext:
       runAsNonRoot: true
       runAsUser: 10001
       fsGroup: 20001                 # kubelet ajusta el group ownership del volumen
       fsGroupChangePolicy: OnRootMismatch
     containers:
       - name: app
         image: busybox:1.36
         command: ["sleep", "3600"]
         securityContext:
           allowPrivilegeEscalation: false
           readOnlyRootFilesystem: true
           capabilities:
             drop: ["ALL"]
         volumeMounts:
           - name: cred
             mountPath: /etc/cred
             readOnly: true
           - name: scratch
             mountPath: /tmp          # espacio escribible explícito
     volumes:
       - name: cred
         secret:
           secretName: demo-cred
           defaultMode: 0400          # solo el owner lee
       - name: scratch
         emptyDir: {}
   ```

   ```bash
   kubectl apply -f vol-perms-hardened.yaml
   kubectl exec vol-perms-hardened -- ls -l /etc/cred/
   kubectl exec vol-perms-hardened -- id
   ```

   Salida esperada:
   ```
   -r--------    1 root     20001  ...  password
   uid=10001 gid=0(root) groups=20001
   ```

5. Comprobá que `readOnlyRootFilesystem` funciona: escribir fuera del `emptyDir` falla, escribir en `/tmp` funciona:

   ```bash
   kubectl exec vol-perms-hardened -- sh -c 'echo x > /root/x'   # falla
   kubectl exec vol-perms-hardened -- sh -c 'echo x > /tmp/x && echo OK'
   ```

   Salida esperada:
   ```
   sh: can't create /root/x: Read-only file system
   command terminated with exit code 1
   ...
   OK
   ```

**Preguntas de comprensión:**

- **P3.1** — En el paso 3 el Secret aparece montado como `tmpfs`. ¿Por qué es una propiedad de seguridad relevante frente a un atacante con acceso al disco del nodo?
- **P3.2** — ¿Qué problema resuelve `fsGroup` y qué hace exactamente el kubelet cuando lo definís? ¿Por qué `fsGroupChangePolicy: OnRootMismatch` importa en volúmenes grandes?
- **P3.3** — `readOnlyRootFilesystem: true` obligó a declarar un `emptyDir` para `/tmp`. ¿Qué ganancia de seguridad da forzar esa declaración explícita?
- **P3.4** — Con `defaultMode: 0400` y `runAsUser: 10001`, ¿el proceso puede leer el Secret? Pista: mirá el `owner` y el `group` del archivo en el paso 4 contra el `id` del proceso.

---

## Ejercicio 4 — Secret como volumen vs. variable de entorno

Ambas formas exponen el Secret al contenedor, pero tienen perfiles de riesgo distintos. El KCSA espera que sepas cuándo cada una es peor.

**Pasos:**

1. Creá un Pod que consume el mismo Secret por **env var**:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: secret-env
     namespace: default
   spec:
     containers:
       - name: app
         image: busybox:1.36
         command: ["sleep", "3600"]
         env:
           - name: DB_PASSWORD
             valueFrom:
               secretKeyRef:
                 name: demo-cred
                 key: password
   ```
   ```bash
   kubectl apply -f secret-env.yaml
   ```

2. Mostrá cómo una env var con un Secret **se filtra al entorno del proceso** — legible por cualquier proceso hijo y por herramientas de diagnóstico:

   ```bash
   kubectl exec secret-env -- printenv DB_PASSWORD
   kubectl exec secret-env -- cat /proc/1/environ | tr '\0' '\n' | grep DB_PASSWORD
   ```

   Salida esperada:
   ```
   S3cr3t-KCSA!
   DB_PASSWORD=S3cr3t-KCSA!
   ```

3. Rotá el Secret y observá la diferencia clave:

   ```bash
   kubectl create secret generic demo-cred \
     --from-literal=password='N3w-P4ss!' \
     -n default --dry-run=client -o yaml | kubectl apply -f -
   ```

4. Comprobá que la **env var NO se actualiza** (queda el valor viejo hasta reiniciar el Pod), mientras que un **volumen SÍ se refresca** (recordá el Pod `vol-perms` del Ej. 3, que monta el mismo Secret):

   ```bash
   kubectl exec secret-env -- printenv DB_PASSWORD        # sigue mostrando el valor viejo
   sleep 70
   kubectl exec vol-perms -- cat /etc/cred/password; echo # muestra el valor nuevo
   ```

   Salida esperada:
   ```
   S3cr3t-KCSA!
   ...
   N3w-P4ss!
   ```

**Preguntas de comprensión:**

- **P4.1** — Enumerá dos formas en que un Secret expuesto como **env var** se filtra que no aplican cuando se monta como **volumen**.
- **P4.2** — En el paso 4, ¿por qué el volumen reflejó el nuevo valor y la env var no? ¿Qué implicancia tiene esto para la **rotación** de credenciales?
- **P4.3** — Un Pod con `subPath` montando un Secret **no** recibe actualizaciones automáticas del volumen. ¿Qué cuidado de seguridad operativa introduce eso?
- **P4.4** — Independientemente de env o volumen, ¿el Secret sigue estando en etcd? ¿Qué control del Ejercicio 1 es el que realmente protege el dato en reposo?

---

## Ejercicio 5 — RBAC sobre storage: crear un PersistentVolume es una escalada de privilegios

`PersistentVolume` es un recurso **cluster-scoped**. Quien puede crear PVs puede definir un PV de tipo `hostPath` que apunte a cualquier ruta del nodo, y luego reclamarlo con una PVC — sorteando el Pod Security Admission del Ejercicio 2.

**Pasos:**

1. Simulá un usuario con un rol "de storage" aparentemente inocuo:

   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: storage-operator
   rules:
     - apiGroups: [""]
       resources: ["persistentvolumes"]
       verbs: ["create", "get", "list"]
   ```
   ```bash
   kubectl apply -f storage-operator-role.yaml
   kubectl create clusterrolebinding storage-op \
     --clusterrole=storage-operator --user=mallory
   ```

2. Como ese usuario, verificá el permiso:

   ```bash
   kubectl auth can-i create persistentvolumes --as=mallory
   ```

   Salida esperada:
   ```
   yes
   ```

3. Creá un PV `hostPath` que apunta a la raíz del nodo:

   ```yaml
   apiVersion: v1
   kind: PersistentVolume
   metadata:
     name: escape-pv
   spec:
     capacity:
       storage: 1Gi
     accessModes: ["ReadWriteOnce"]
     hostPath:
       path: /                       # ← toda la raíz del host
     persistentVolumeReclaimPolicy: Retain
   ```
   ```bash
   kubectl apply -f escape-pv.yaml --as=mallory
   ```

   Salida esperada:
   ```
   persistentvolume/escape-pv created
   ```

   Con una PVC que haga `bind` a este PV, un Pod que no toca directamente `hostPath` termina montando `/` del nodo — evadiendo Baseline, que solo inspecciona `volumes[*].hostPath`, no PVCs.

4. Revisá qué otros recursos de storage son sensibles en RBAC:

   ```bash
   kubectl api-resources | egrep 'persistentvolume|storageclass|csidriver|csinode|volumeattachment'
   ```

   Salida esperada (fragmento):
   ```
   persistentvolumes                 v1            false   PersistentVolume
   csidrivers          storage.k8s.io/v1           false   CSIDriver
   csinodes            storage.k8s.io/v1           false   CSINode
   storageclasses      storage.k8s.io/v1           false   StorageClass
   volumeattachments   storage.k8s.io/v1           false   VolumeAttachment
   ```
   Todos `false` en la columna *NAMESPACED*: son **cluster-scoped**, así que un rol namespaced no los limita.

**Preguntas de comprensión:**

- **P5.1** — ¿Por qué `create persistentvolumes` es efectivamente equivalente a acceso root al nodo, aunque el rol no mencione `hostPath` ni `privileged`?
- **P5.2** — Pod Security Admission bloqueó el `hostPath` directo en el Ejercicio 2, pero no este ataque. ¿Por qué la PVC evade ese control, y qué capa lo detendría (pista: un admission controller de políticas como los que valida el examen)?
- **P5.3** — De la lista del paso 4, ¿por qué `csidrivers` es especialmente peligroso? Pensá en `podInfoOnMount` y en drivers que corren con privilegios en cada nodo.
- **P5.4** — ¿Cómo restringirías `StorageClass` para que un tenant no pueda usar un provisioner que monte almacenamiento del host o de otro tenant?

---

## Ejercicio 6 — Mount propagation: cómo un montaje se escapa al host (diagnóstico avanzado)

`mountPropagation: Bidirectional` permite que montajes hechos **dentro** del contenedor se propaguen de vuelta al **nodo**. Requiere contenedor privilegiado, y es la base de varios CVEs de escape.

**Pasos:**

1. Inspeccioná los tres modos posibles y su relación con privilegios:

   ```
   None            → aislado; montajes posteriores no se ven en ningún sentido (default)
   HostToContainer → el contenedor VE montajes nuevos del host (slave)
   Bidirectional   → el contenedor VE y PROPAGA montajes al host (shared) — exige privileged: true
   ```

2. Detectá Pods con propagación peligrosa en el cluster:

   ```bash
   kubectl get pods -A -o json | jq -r '
     .items[] | . as $p |
     $p.spec.containers[]?.volumeMounts[]? |
     select(.mountPropagation=="Bidirectional") |
     "\($p.metadata.namespace)/\($p.metadata.name): \(.name) -> \(.mountPath)"'
   ```

   Salida esperada en un cluster limpio: **sin resultados**. Cualquier fila que aparezca merece una revisión: ese contenedor puede alterar los mounts del nodo.

3. Correlacioná con privilegios (Bidirectional exige `privileged: true`, así que buscá ambos):

   ```bash
   kubectl get pods -A -o json | jq -r '
     .items[] | . as $p |
     $p.spec.containers[]? |
     select(.securityContext.privileged==true) |
     "\($p.metadata.namespace)/\($p.metadata.name): \(.name) [privileged]"'
   ```

4. Confirmá el bloqueo por política: un Pod con `Bidirectional` pero sin `privileged` es rechazado por el propio API server:

   ```
   Error: Pod "x" is invalid: spec.containers[0].volumeMounts[0].mountPropagation:
   Forbidden: Bidirectional mount propagation is available only to privileged containers
   ```

**Preguntas de comprensión:**

- **P6.1** — ¿Por qué `Bidirectional` está atado a `privileged: true`? ¿Qué garantía de aislamiento rompe?
- **P6.2** — Un CSI node driver legítimo suele necesitar `Bidirectional` para exponer volúmenes montados al kubelet. ¿Cómo distinguís ese uso legítimo de un intento de escape en la auditoría del paso 2?
- **P6.3** — El perfil **Baseline** ya prohíbe contenedores privilegiados. ¿Eso elimina por completo el riesgo de `Bidirectional` en un namespace Baseline? ¿Y en un namespace sin PSA?

---

<details>
<summary><strong>Respuestas</strong></summary>

**Ejercicio 1**

- **P1.1** — base64 es una **codificación reversible sin clave**, no cifrado: `base64 -d` recupera el texto plano sin secreto alguno. "Cifrado" implica que sin la clave el dato es inútil. Por defecto Kubernetes guarda el Secret en etcd tal cual (base64), así que quien lee el disco de etcd o un backup lee la credencial. Solo `EncryptionConfiguration` (o KMS) lo cifra realmente en reposo.
- **P1.2** — El **primer provider de la lista se usa para escribir**. Si `identity` va primero, todas las escrituras nuevas quedan **en texto plano** (`identity` = sin cifrado); `aescbc` solo serviría para *leer* lo que ya estuviera cifrado. Es exactamente la configuración que se usa para **desactivar** el cifrado. Para cifrar, el provider real va primero e `identity` al final.
- **P1.3** — El cambio solo afecta a **escrituras futuras**. Los Secrets creados antes siguen en texto plano en etcd hasta que se **reescriben**. `kubectl get ... | kubectl replace -f -` fuerza una reescritura de todos, disparando el cifrado. Si lo omitís, cada Secret preexistente (incluyendo tokens de service accounts históricos) sigue expuesto en etcd.
- **P1.4** — Con `aescbc` la **clave de cifrado está en texto plano en el archivo de configuración del nodo del control plane**: quien lee ese archivo (o su backup) descifra todo etcd. **KMS v2** delega el cifrado a un KMS externo (envelope encryption): la clave raíz (KEK) nunca toca el disco del nodo, las DEKs se rotan, hay auditoría y revocación centralizadas, y v2 mejora el rendimiento/caché frente a v1. Es la opción recomendada para producción.

**Ejercicio 2**

- **P2.1** — No. `readOnly: true` impide **escribir** el filesystem del host, pero **leer** ya es un compromiso total: en el paso 2 leíste `kubelet.conf` y podés leer `/var/lib/kubelet/pki`, tokens de service accounts montados en el nodo, claves TLS, `/etc/shadow`, etc. La confidencialidad del nodo se pierde con solo lectura.
- **P2.2** — Leer `kubelet.conf` te da la **identidad del kubelet** (credenciales para hablar con la API como ese nodo — grave, pero acotado por Node Authorization/NodeRestriction). El **socket del runtime** (`containerd.sock`/`docker.sock`) te permite **crear un contenedor privilegiado nuevo montando `/`** — control total del nodo, sin pasar por la API de Kubernetes ni por sus controles de admisión. Es escalada directa a root en el host.
- **P2.3** — `enforce` **rechaza** los Pods que violan el perfil; `warn` los **admite pero avisa** al usuario en la respuesta de la API; `audit` los admite y registra un **evento en el audit log**. Durante una migración querés los tres: `audit`+`warn` en el nivel objetivo para **descubrir** qué cargas romperían sin bloquear nada, y `enforce` en un nivel más laxo, hasta que estés seguro de subir `enforce` al nivel objetivo sin cortar producción.
- **P2.4** — Aislar la carga privilegiada en su **propio namespace** con una etiqueta PSA más permisiva (p. ej. `enforce=privileged`) y RBAC estrecho, en vez de bajar el Baseline del namespace compartido. Alternativamente, políticas más finas (Kyverno/Validating Admission Policy) que permitan **solo** el `hostPath` específico (`/var/log`, `readOnly`) para ese ServiceAccount. El principio: excepción mínima y localizada, nunca abrir el namespace entero.

**Ejercicio 3**

- **P3.1** — Los volúmenes de tipo `secret`, `configMap`, `downwardAPI` y `projected` se montan en **tmpfs (RAM)**, no se escriben en el disco del nodo. Un atacante con acceso al **disco** del nodo (o a un snapshot/backup del volumen del nodo) no encuentra el Secret ahí; además, al terminar el Pod la memoria se libera y no queda rastro en disco.
- **P3.2** — `fsGroup` hace que el kubelet **ajuste el group ownership** (chown al GID indicado) y agregue el bit setgid al montar el volumen, de modo que un proceso que corre como usuario no-root pero miembro de ese grupo pueda leer/escribir el volumen sin correr como root. En volúmenes grandes, chownear **recursivamente en cada arranque** es caro; `fsGroupChangePolicy: OnRootMismatch` solo lo hace si el **owner del directorio raíz del volumen** no coincide, evitando el recorrido completo cuando ya está bien.
- **P3.3** — Fuerza a **enumerar explícitamente** cada ruta escribible que la aplicación necesita, en vez de dejar todo el filesystem mutable. Reduce la superficie: un atacante no puede sobrescribir binarios, `/etc`, ni dejar payloads persistentes; solo puede tocar los `emptyDir` declarados (efímeros, que desaparecen con el Pod). También expone en el manifiesto, de forma auditable, exactamente qué escribe la app.
- **P3.4** — Sí puede. El archivo quedó `-r--------` con **owner root** y **group 20001** (por `fsGroup`). El proceso corre como `uid=10001` con `groups=20001`. `0400` da lectura **solo al owner**... pero fijate: el modo efectivo combinado con `fsGroup` hace que el grupo del archivo sea `20001` y el proceso pertenece a él. En la práctica, para Secrets montados con `fsGroup`, el kubelet aplica los permisos de forma que el grupo `fsGroup` pueda leer; el proceso `10001`/grupo `20001` lee el archivo. (Si quisieras negarlo también al grupo, usarías `0400` **sin** incluir a ese proceso en `fsGroup`.)

**Ejercicio 4**

- **P4.1** — (1) Queda en `/proc/<pid>/environ`, **heredada por todo proceso hijo** (un `exec` de una herramienta de terceros la ve). (2) Aparece con frecuencia en **logs, dumps de crash, mensajes de error y trazas de debug** que imprimen el entorno; y herramientas de introspección/telemetría suelen volcar env vars. El volumen, en cambio, es un archivo con permisos, en tmpfs, no heredado por el entorno de procesos.
- **P4.2** — El volumen de Secret lo **refresca el kubelet periódicamente** (proyecta el valor actual del Secret en el archivo montado, con cierta latencia de propagación). La env var se **resuelve una sola vez al crear el contenedor** y queda congelada. Implicancia: para **rotar** una credencial sin reiniciar Pods, usá volumen; con env var, rotar exige un **rollout/reinicio** de todos los Pods que la consumen.
- **P4.3** — `subPath` **rompe la actualización automática**: monta una copia del archivo en el momento de arranque y no recibe los refrescos del kubelet. O sea, rotás el Secret y esos Pods **siguen usando el valor viejo silenciosamente** hasta reiniciarse — un riesgo operativo (credencial rotada que se cree revocada pero sigue viva en memoria del Pod).
- **P4.4** — Sí: en ambos casos el dato reside en **etcd**. Ni env ni volumen cambian eso. El único control que protege el dato **en reposo** es el **Encryption at Rest / KMS** del Ejercicio 1, más TLS y control de acceso a etcd y a sus backups.

**Ejercicio 5**

- **P5.1** — Porque `PersistentVolume` es cluster-scoped y admite `spec.hostPath`. Quien puede crear PVs define uno que apunta a `/` (o a `/var/lib/kubelet`, `/etc/kubernetes`, el socket del runtime) y luego lo reclama con una PVC desde un Pod normal. El Pod termina montando esa ruta del nodo sin declarar `hostPath` en su propio spec — control efectivo del host. El rol "solo storage" es, en realidad, un rol de escape de nodo.
- **P5.2** — Pod Security Admission inspecciona `spec.volumes[*].hostPath` del **Pod**. Aquí el Pod solo declara un `persistentVolumeClaim`; el `hostPath` vive en el **PV**, un objeto separado que PSA no correlaciona. Lo detiene una capa de **política de admisión** (Kyverno, OPA/Gatekeeper o **Validating Admission Policy**) que valide los PV/PVC — p. ej. prohibir PVs `hostPath` o restringir sus rutas — o simplemente **no otorgar** `create persistentvolumes` a tenants.
- **P5.3** — Un `CSIDriver` corre su componente **node** como DaemonSet **privilegiado en cada nodo**, con acceso a montajes y frecuentemente a `hostPath`. Registrar o modificar un `CSIDriver` malicioso (o con `podInfoOnMount: true`, que le entrega metadatos del Pod incluyendo tokens) da ejecución privilegiada distribuida por todo el cluster. Es una de las vías de compromiso más amplias del subsistema de storage.
- **P5.4** — Con **RBAC** limitá `get/list/watch/use` de `storageclasses` al StorageClass permitido y negá `create` de PVs a los tenants. Definí un `default` StorageClass seguro y usá **ResourceQuota**/políticas de admisión para forzar que las PVCs solo referencien StorageClasses aprobadas (provisioners que aíslan por tenant y no exponen almacenamiento del host). Nunca permitas provisioners de tipo `hostPath`/`local` a tenants no confiables.

**Ejercicio 6**

- **P6.1** — `Bidirectional` (shared mount) hace que un `mount` realizado **dentro** del contenedor se propague al **namespace de montaje del host**. Eso rompe el aislamiento del mount namespace — el pilar de la contención del contenedor — permitiendo alterar el árbol de montajes del nodo (montar sobre rutas del host, exponer dispositivos). Por eso Kubernetes lo restringe a contenedores `privileged`, que de todos modos ya renuncian al aislamiento.
- **P6.2** — Por **identidad y contexto**, no por el flag en sí: un uso legítimo pertenece a un **DaemonSet de un CSI node driver conocido** (namespace del sistema de storage, imagen del proveedor del driver, ServiceAccount esperado, monta el directorio de plugins del kubelet). Una fila sospechosa es un Pod de aplicación arbitrario, en un namespace de usuario, con imagen no relacionada con storage. La auditoría no debe alarmarse por el patrón, sino por **quién** lo usa.
- **P6.3** — En un namespace **Baseline**, sí queda mitigado en la práctica: sin `privileged` no se puede pedir `Bidirectional` (el API server lo rechaza), y Baseline prohíbe `privileged`. En un namespace **sin PSA**, no: cualquiera que pueda crear Pods puede pedir `privileged: true` + `Bidirectional` y escapar al host. La defensa completa combina PSA/política de admisión **más** RBAC que restrinja quién crea Pods privilegiados.

</details>

---

**Fuentes de referencia:**
- CNCF, *KCSA Curriculum* — https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
- Kubernetes, *Encrypting Confidential Data at Rest* — https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
- Kubernetes, *Using a KMS provider for data encryption* — https://kubernetes.io/docs/tasks/administer-cluster/kms-provider/
- Kubernetes, *Pod Security Standards* — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Kubernetes, *Configure a Security Context for a Pod or Container* — https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- Kubernetes, *Secrets* — https://kubernetes.io/docs/concepts/configuration/secret/
- Kubernetes, *Volumes* (`hostPath`, `mountPropagation`) — https://kubernetes.io/docs/concepts/storage/volumes/
- Kubernetes, *Using RBAC Authorization* — https://kubernetes.io/docs/reference/access-authn-authz/rbac/