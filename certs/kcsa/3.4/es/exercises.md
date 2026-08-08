# Tema 3.4 — Secrets: Ejercicios guiados

> **Prerrequisitos:** un cluster de práctica donde tengas acceso al control plane (kubeadm, kind o minikube sirven; para el Ejercicio 2 necesitás poder editar el manifiesto estático de `kube-apiserver` o los flags del cluster). Trabajá siempre en un namespace desechable:
>
> ```bash
> kubectl create namespace kcsa-secrets
> kubectl config set-context --current --namespace=kcsa-secrets
> ```
>
> **Fuente base del tema:** *KCSA Curriculum* (dominio *Kubernetes Security Fundamentals → Secrets*) — https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf

---

## Ejercicio 1 — base64 no es cifrado: la propiedad más malentendida de un Secret

El objetivo es interiorizar que un `Secret` **por defecto no protege el valor**: solo lo codifica. Cualquiera con permiso de lectura sobre el objeto obtiene el texto plano.

1. Creá un Secret de tipo `Opaque` con dos claves:

   ```bash
   kubectl create secret generic app-creds \
     --from-literal=username=admin \
     --from-literal=password='S3cr3t-P@ss'
   ```

2. Miralo tal como lo guarda la API, sin decodificar:

   ```bash
   kubectl get secret app-creds -o yaml
   ```

   Salida esperada (recortada):

   ```yaml
   apiVersion: v1
   kind: Secret
   type: Opaque
   metadata:
     name: app-creds
     namespace: kcsa-secrets
   data:
     password: UzNjcjN0LVBAc3M=
     username: YWRtaW4=
   ```

3. Revertí la "protección" con una sola orden que no requiere ningún privilegio especial:

   ```bash
   kubectl get secret app-creds -o jsonpath='{.data.password}' | base64 -d; echo
   ```

   Salida esperada:

   ```
   S3cr3t-P@ss
   ```

4. Comprobá que `kubectl describe` **no** muestra el valor (solo el tamaño en bytes), lo cual es fácil de confundir con "está oculto de forma segura":

   ```bash
   kubectl describe secret app-creds
   ```

   Salida esperada (recortada):

   ```
   Type:  Opaque
   Data
   ====
   password:  11 bytes
   username:  5 bytes
   ```

**Preguntas de verificación:**

- **1a.** Un compañero dice: "los Secrets están cifrados, por eso `kubectl describe` no muestra el valor". ¿Es correcto? Justificá.
- **1b.** ¿Qué transformación aplica realmente el campo `data` de un Secret y qué garantía de seguridad ofrece esa transformación?
- **1c.** Si base64 no protege el valor, ¿cuál es entonces la ventaja de usar un objeto `Secret` en lugar de un `ConfigMap` para credenciales?

---

## Ejercicio 2 — Cifrado en reposo (encryption at rest) en etcd

Los Secrets viven en `etcd`. Sin configuración adicional, se almacenan **en texto plano** (base64) dentro de la base de datos del control plane. Un atacante con acceso al disco de etcd, a un backup, o a un snapshot, lee todos los Secrets del cluster.

1. Confirmá cómo llega hoy el Secret a etcd (ejecutá dentro del control plane, ajustando los paths de los certs a tu cluster):

   ```bash
   ETCDCTL_API=3 etcdctl \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     get /registry/secrets/kcsa-secrets/app-creds | hexdump -C | head
   ```

   Verás fragmentos legibles como `k8s`, `Opaque`, `admin`: el valor está **sin cifrar**.

2. Generá una clave AES de 32 bytes y creá un `EncryptionConfiguration`:

   ```bash
   head -c 32 /dev/urandom | base64
   ```

   Guardá `/etc/kubernetes/enc/enc.yaml` en el nodo del control plane:

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
                 secret: <PEGÁ_AQUÍ_LA_CLAVE_BASE64>
         - identity: {}
   ```

3. Referenciá el archivo desde el `kube-apiserver` (en un cluster kubeadm, editá `/etc/kubernetes/manifests/kube-apiserver.yaml` y agregá el flag; el kubelet reinicia el pod estático solo):

   ```yaml
   - --encryption-provider-config=/etc/kubernetes/enc/enc.yaml
   ```

   (Recordá montar el directorio `/etc/kubernetes/enc` como `volume`/`volumeMount` en el pod estático.)

4. Re-cifrá los Secrets ya existentes (los viejos siguen en texto plano hasta que se reescriben):

   ```bash
   kubectl get secrets --all-namespaces -o json | kubectl replace -f -
   ```

5. Repetí el `etcdctl get` del paso 1. Salida esperada (recortada):

   ```
   /registry/secrets/kcsa-secrets/app-creds
   k8s:enc:aescbc:v1:key1:<bytes binarios ilegibles>
   ```

   El prefijo `k8s:enc:aescbc:v1:key1:` confirma que el provider `aescbc` cifró el objeto.

**Preguntas de verificación:**

- **2a.** En la lista `providers`, `aescbc` aparece **antes** de `identity`. ¿Qué provider se usa para *escribir* y por qué el orden importa? ¿Qué pasaría si invirtieras el orden?
- **2b.** Después de activar el cifrado, ¿por qué es imprescindible el paso 4 (`kubectl replace`)? ¿Qué Secrets quedarían aún en texto plano si lo omitís?
- **2c.** El cifrado con `aescbc` guarda la clave en un archivo en el disco del control plane. ¿Qué provider recomienda Kubernetes para producción de forma de no tener la clave maestra en el mismo nodo, y qué componente externo introduce?
- **2d.** El cifrado en reposo protege contra un robo del disco/backup de etcd. Nombrá **un** vector de exposición que este control **no** mitiga.

> Fuentes: *Encrypting Confidential Data at Rest* — https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/ · *Using a KMS provider for data encryption* — https://kubernetes.io/docs/tasks/administer-cluster/kms-provider/

---

## Ejercicio 3 — Least privilege: RBAC sobre Secrets

El acceso a Secrets se gobierna con RBAC. El error clásico es otorgar `get`/`list` sobre `secrets` de forma amplia — o peor, dar acceso a `secrets` a nivel de cluster.

1. Creá una `ServiceAccount` que representará a una aplicación:

   ```bash
   kubectl create serviceaccount app-sa
   ```

2. Creá un `Role` que **solo** puede leer un Secret puntual por nombre (least privilege real: `resourceNames`):

   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: read-app-creds
     namespace: kcsa-secrets
   rules:
     - apiGroups: [""]
       resources: ["secrets"]
       resourceNames: ["app-creds"]
       verbs: ["get"]
   ```

   ```bash
   kubectl apply -f role.yaml
   kubectl create rolebinding app-sa-read-creds \
     --role=read-app-creds \
     --serviceaccount=kcsa-secrets:app-sa
   ```

3. Verificá los permisos con `auth can-i` suplantando a la ServiceAccount:

   ```bash
   kubectl auth can-i get secret/app-creds \
     --as=system:serviceaccount:kcsa-secrets:app-sa -n kcsa-secrets
   # yes

   kubectl auth can-i list secrets \
     --as=system:serviceaccount:kcsa-secrets:app-sa -n kcsa-secrets
   # no

   kubectl auth can-i get secret/otro-secret \
     --as=system:serviceaccount:kcsa-secrets:app-sa -n kcsa-secrets
   # no
   ```

4. Detectá un antipatrón: buscá quién puede leer **todos** los Secrets del cluster.

   ```bash
   kubectl get clusterrolebindings -o json \
     | jq -r '.items[] | select(.roleRef.name=="cluster-admin") | .metadata.name'
   ```

**Preguntas de verificación:**

- **3a.** ¿Por qué `list` sobre `secrets` es más peligroso que un `get` con `resourceNames`? ¿Qué obtiene el titular de `list` que no puede acotarse con `resourceNames`?
- **3b.** ¿Por qué el verbo `list` (y `watch`) **no** puede restringirse por `resourceNames`, mientras que `get`, `update` y `delete` sí?
- **3c.** Un `Role` que otorga `get secrets` sin `resourceNames` en el namespace `kube-system`. ¿Por qué es especialmente grave? (Pista: ¿qué tipo de Secrets vive ahí?)
- **3d.** ¿Qué relación hay entre "poder crear Pods en un namespace" y "poder leer los Secrets de ese namespace", aunque no tengas el verbo `get secrets`?

> Fuente: *Using RBAC Authorization* — https://kubernetes.io/docs/reference/access-authn-authz/rbac/

---

## Ejercicio 4 — Superficie de exposición: env vars vs. volume mounts

Un Secret se consume de dos formas, y **no** son equivalentes en seguridad.

1. Creá un Pod que consuma el mismo Secret por variable de entorno **y** por volumen:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: consumer
   spec:
     serviceAccountName: app-sa
     containers:
       - name: app
         image: busybox:1.36
         command: ["sh", "-c", "sleep 3600"]
         env:
           - name: PASSWORD
             valueFrom:
               secretKeyRef:
                 name: app-creds
                 key: password
         volumeMounts:
           - name: creds
             mountPath: /etc/creds
             readOnly: true
     volumes:
       - name: creds
         secret:
           secretName: app-creds
   ```

   ```bash
   kubectl apply -f consumer.yaml
   ```

2. Observá la exposición por **variable de entorno**:

   ```bash
   kubectl exec consumer -- env | grep PASSWORD
   # PASSWORD=S3cr3t-P@ss

   kubectl exec consumer -- cat /proc/1/environ | tr '\0' '\n' | grep PASSWORD
   # PASSWORD=S3cr3t-P@ss
   ```

   La variable está en `/proc/1/environ`: cualquier proceso del contenedor (o un dump de crash, o un log que imprima `env`) la revela, y **todo proceso hijo la hereda**.

3. Observá la exposición por **volumen** (tmpfs en RAM):

   ```bash
   kubectl exec consumer -- cat /etc/creds/password; echo
   # S3cr3t-P@ss

   kubectl exec consumer -- mount | grep /etc/creds
   # tmpfs on /etc/creds type tmpfs (ro,relatime)
   ```

   El montaje es `tmpfs` (memoria, no disco) y `ro`. No aparece en el entorno del proceso ni lo heredan los hijos.

4. Comprobá la propagación automática: editá el valor del Secret y mirá que el **volumen** se actualiza solo, mientras que la **variable de entorno no** (queda congelada al valor de arranque del Pod):

   ```bash
   kubectl patch secret app-creds \
     --type='json' \
     -p='[{"op":"replace","path":"/data/password","value":"'$(echo -n 'NUEVO-pass' | base64)'"}]'

   sleep 70
   kubectl exec consumer -- cat /etc/creds/password; echo   # NUEVO-pass  (se actualizó)
   kubectl exec consumer -- printenv PASSWORD               # S3cr3t-P@ss (sigue viejo)
   ```

**Preguntas de verificación:**

- **4a.** Enumerá tres vías por las que un Secret expuesto como variable de entorno puede filtrarse y que **no** aplican al montaje como volumen.
- **4b.** ¿Por qué el valor montado como volumen se actualiza tras editar el Secret, pero la variable de entorno no? ¿Qué implica esto para la **rotación** de credenciales?
- **4c.** El montaje aparece como `tmpfs`. ¿Qué ventaja de seguridad aporta que el Secret esté en RAM y no escrito en el disco del nodo?
- **4d.** ¿En qué situación real un `readOnly: true` en el `volumeMount` evita un problema concreto?

> Fuente: *Secrets — Consuming Secrets* — https://kubernetes.io/docs/concepts/configuration/secret/

---

## Ejercicio 5 — Tokens de ServiceAccount: auto-montaje, bound tokens y proyección

El Secret que casi nadie crea a mano pero que **todo Pod recibe** es el token de su ServiceAccount: una credencial hacia la API server. Es el objetivo número uno tras comprometer un contenedor.

1. Mirá el token que un Pod recibe por defecto y de dónde sale:

   ```bash
   kubectl exec consumer -- ls /var/run/secrets/kubernetes.io/serviceaccount/
   # ca.crt  namespace  token
   ```

   Ese `token` es un JWT firmado. Decodificá su payload (sin verificarlo) para ver que es un **bound token** con expiración y audiencia:

   ```bash
   kubectl exec consumer -- cat /var/run/secrets/kubernetes.io/serviceaccount/token \
     | cut -d. -f2 | base64 -d 2>/dev/null | jq
   ```

   Salida esperada (recortada):

   ```json
   {
     "aud": ["https://kubernetes.default.svc"],
     "exp": 1754600000,
     "iat": 1754596400,
     "kubernetes.io": {
       "namespace": "kcsa-secrets",
       "pod": { "name": "consumer" },
       "serviceaccount": { "name": "app-sa" }
     }
   }
   ```

2. Aplicá el principio de "no montes lo que no usás": desactivá el auto-montaje del token cuando el Pod **no** llama a la API:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: no-token
   spec:
     serviceAccountName: app-sa
     automountServiceAccountToken: false
     containers:
       - name: app
         image: busybox:1.36
         command: ["sh", "-c", "sleep 3600"]
   ```

   ```bash
   kubectl apply -f no-token.yaml
   kubectl exec no-token -- ls /var/run/secrets/kubernetes.io/serviceaccount/ 2>&1
   # ls: /var/run/secrets/kubernetes.io/serviceaccount/: No such file or directory
   ```

3. Cuando el Pod **sí** necesita un token, usá un `projected volume` con audiencia y expiración cortas en vez del token amplio por defecto:

   ```yaml
       volumes:
         - name: api-token
           projected:
             sources:
               - serviceAccountToken:
                   path: token
                   audience: vault
                   expirationSeconds: 600
   ```

**Preguntas de verificación:**

- **5a.** ¿Qué diferencia hay entre los antiguos tokens de ServiceAccount (Secrets de tipo `kubernetes.io/service-account-token` de larga duración) y los *bound tokens* que hoy monta el kubelet? Nombrá dos propiedades de seguridad que aportan los bound tokens.
- **5b.** ¿Por qué `automountServiceAccountToken: false` reduce el blast radius de un contenedor comprometido? ¿Qué puede hacer un atacante con un token de SA válido montado?
- **5c.** ¿Para qué sirven los campos `audience` y `expirationSeconds` de un token proyectado? ¿Qué ataque mitiga una `audience` acotada si el token se filtra a un servicio externo?
- **5d.** Un Pod con la SA `default` en un namespace donde esa SA tiene permisos amplios. ¿Por qué es mala práctica usar la SA `default` para cargas reales?

> Fuente: *Managing Service Accounts / Bound Service Account Tokens* — https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/ · https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/

---

## Ejercicio 6 — Endurecimiento: Secrets inmutables y gestión externa

Dos controles que separan un cluster de laboratorio de uno de producción: Secrets inmutables (reducen carga y previenen cambios accidentales/maliciosos) y externalizar el ciclo de vida a un gestor dedicado.

1. Marcá un Secret como `immutable`. Una vez inmutable, no se puede editar `data`; solo borrar y recrear:

   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: tls-config
   type: Opaque
   immutable: true
   data:
     token: c3VwZXItdG9rZW4=
   ```

   ```bash
   kubectl apply -f immutable.yaml
   kubectl patch secret tls-config -p '{"data":{"token":"eGVnYQ=="}}'
   ```

   Salida esperada:

   ```
   The Secret "tls-config" is invalid: data: Forbidden: field is immutable when `immutable` is set
   ```

2. (Conceptual — no requiere instalar nada) Revisá cómo un flujo con gestor externo cambia el modelo de confianza. Con el **External Secrets Operator**, el objeto que versionás en Git no contiene el valor:

   ```yaml
   apiVersion: external-secrets.io/v1beta1
   kind: ExternalSecret
   metadata:
     name: app-creds
   spec:
     refreshInterval: 1h
     secretStoreRef:
       name: vault-backend
       kind: SecretStore
     target:
       name: app-creds        # el Secret nativo que se materializa en el cluster
     data:
       - secretKey: password
         remoteRef:
           key: secret/data/app
           property: password
   ```

3. Contrastalo con el **Secrets Store CSI Driver**, que monta el secreto desde el gestor externo directo en el Pod como volumen, sin (opcionalmente) crear un objeto `Secret` en etcd.

**Preguntas de verificación:**

- **6a.** Además de prevenir modificaciones accidentales, ¿qué beneficio de rendimiento/escala aporta `immutable: true` en clusters con muchos Pods? (Pista: el kubelet *watchea* los Secrets montados.)
- **6b.** En el flujo con External Secrets Operator, ¿qué es exactamente lo que se guarda en el repositorio Git y por qué eso mejora la postura de seguridad respecto de commitear un `Secret` normal?
- **6c.** Nombrá una diferencia de superficie de ataque entre el External Secrets Operator (materializa un `Secret` nativo en etcd) y el Secrets Store CSI Driver (puede montar sin persistir en etcd).
- **6d.** ¿Por qué "no commitear Secrets en el repositorio" sigue siendo necesario aunque tengas cifrado en reposo activado (Ejercicio 2)?

> Fuentes: *Secrets — Immutable Secrets* — https://kubernetes.io/docs/concepts/configuration/secret/#secret-immutable · *Secrets Store CSI Driver* — https://secrets-store-csi-driver.sigs.k8s.io/ · *External Secrets Operator* — https://external-secrets.io/

---

## Limpieza

```bash
kubectl delete namespace kcsa-secrets
kubectl config set-context --current --namespace=default
```

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1

- **1a.** Es **incorrecto**. Los Secrets **no** están cifrados por defecto; el campo `data` está codificado en **base64**, que es reversible por cualquiera sin clave (`base64 -d`). `kubectl describe` oculta el valor solo por conveniencia de la salida (muestra el tamaño en bytes), no por un control criptográfico. La confusión "no lo veo en describe ⇒ está protegido" es peligrosa.
- **1b.** Aplica **base64**, una codificación, no un cifrado. Su único propósito es permitir transportar bytes binarios (certificados, claves) dentro de un campo de texto YAML/JSON. No aporta **ninguna** garantía de confidencialidad, integridad ni autenticidad.
- **1c.** Las ventajas de `Secret` sobre `ConfigMap` no vienen del base64 sino del **tratamiento especial** que Kubernetes da al tipo: puede cifrarse en reposo (encryption at rest), se monta como `tmpfs` en RAM en vez de disco, se puede marcar como no auto-montable, `kubectl describe`/logs evitan imprimir su valor, y RBAC/auditoría suelen tratarlo como recurso sensible. Es una *señal de intención* que habilita controles, no protección en sí misma.

### Ejercicio 2

- **2a.** El **primer** provider de la lista es el que **escribe** (cifra). Con `aescbc` primero, los objetos nuevos y reescritos se cifran con AES-CBC; `identity` queda de segundo para poder **leer** los objetos viejos aún en texto plano durante la transición. Si invirtieras el orden (`identity` primero), la API server escribiría **en texto plano** y no cifraría nada — es justamente la configuración que se usa a propósito para *descifrar* todo antes de retirar el cifrado.
- **2b.** El cifrado solo se aplica cuando un objeto se **escribe**. Los Secrets creados antes de activar el provider siguen en etcd en su forma anterior (texto plano) hasta que algo los reescriba. `kubectl get secrets ... | kubectl replace -f -` fuerza esa reescritura. Sin ese paso, todos los Secrets preexistentes quedarían legibles en un backup de etcd.
- **2c.** El provider **KMS (v2)**, que delega el cifrado en un **Key Management Service externo** (por ejemplo el KMS de un cloud, o HashiCorp Vault vía plugin). La clave de cifrado de datos (DEK) se envuelve con una clave maestra (KEK) que vive en el KMS, no en el disco del control plane. Así, robar el nodo no basta para descifrar.
- **2d.** No mitiga la exposición **en tiempo de ejecución** ni **en tránsito lógico**: cualquiera con RBAC de lectura sobre el Secret sigue obteniendo el texto plano vía la API (la API server lo descifra antes de devolverlo); tampoco protege contra un token de SA robado, un Pod que imprime el valor, o un administrador malicioso. Encryption at rest cubre únicamente el escenario de acceso al almacenamiento físico/backup de etcd.

### Ejercicio 3

- **3a.** `get` con `resourceNames` limita al titular a **un** Secret nombrado explícitamente. `list secrets` devuelve **todos** los Secrets del namespace *con sus valores* en una sola llamada — y no puede acotarse por nombre (ver 3b). Un permiso de `list` es, en la práctica, "leé todo lo que haya y todo lo que llegue a existir en el futuro" en ese namespace.
- **3b.** `resourceNames` funciona con verbos que operan sobre un objeto **individual identificado por nombre** (`get`, `update`, `patch`, `delete`). `list` y `watch` son operaciones sobre una **colección**: se resuelven antes de conocer los nombres de los ítems, así que el authorizer no tiene un nombre contra el cual filtrar. Por eso restringir por `resourceNames` no tiene efecto sobre `list`/`watch`.
- **3c.** En `kube-system` viven Secrets de altísimo privilegio: tokens de ServiceAccounts de componentes del control plane, credenciales de controllers, a veces claves de cloud providers. `get secrets` amplio ahí equivale a un camino directo hacia **escalada a cluster-admin**.
- **3d.** Quien puede **crear Pods** en un namespace puede montar cualquier Secret de ese namespace como volumen o env var dentro de un Pod que él controla, y leer el valor desde el contenedor — sin necesitar el verbo `get secrets`. Por eso "crear Pods" es un permiso tan sensible como "leer Secrets", y ambos deben acotarse por namespace y least privilege.

### Ejercicio 4

- **4a.** (1) Aparecen en `/proc/<pid>/environ` y las **heredan todos los procesos hijos**; (2) se filtran fácil en logs o mensajes de error que vuelcan el entorno (`env`, stack traces, crash dumps); (3) herramientas de introspección, sidecars o un `kubectl describe pod` del *spec* pueden exponer cómo se inyectan, y muchos runtimes las incluyen en su metadata. El volumen no sufre ninguna de estas: no está en el entorno del proceso ni se hereda.
- **4b.** El volumen tipo `secret` es **watcheado** por el kubelet, que refresca el archivo montado cuando el Secret cambia (con un retardo del orden de un minuto por caché/sync). Las variables de entorno se resuelven **una sola vez al arrancar el contenedor** y quedan fijas hasta un reinicio. Implicación para rotación: para que un cambio de credencial tenga efecto sin recrear el Pod, hay que consumirla como **volumen** (y que la app relea el archivo); con env vars, rotar exige reiniciar el Pod.
- **4c.** `tmpfs` mantiene el Secret en **memoria RAM**, no lo escribe en el disco del nodo. Así no queda persistido en el almacenamiento del host (ni en snapshots/backups del disco del nodo) y desaparece cuando el Pod termina, reduciendo la ventana y las copias del valor sensible.
- **4d.** `readOnly: true` impide que un proceso comprometido dentro del contenedor **sobrescriba** el contenido montado — por ejemplo, para inyectar una credencial falsa que otro contenedor del Pod luego lea, o para manipular un certificado montado. También evita corrupción accidental del material sensible.

### Ejercicio 5

- **5a.** Los tokens antiguos eran Secrets de tipo `kubernetes.io/service-account-token`: **sin expiración**, sin audiencia, válidos indefinidamente y almacenados en etcd. Los **bound tokens** (TokenRequest API, montados por el kubelet vía projected volume) están **acotados en el tiempo** (expiran y se rotan automáticamente), **acotados a una audiencia**, y **ligados a la vida del Pod** (dejan de ser válidos si el Pod desaparece). Dos propiedades clave: expiración/rotación automática y binding al Pod → mucho menor valor para un atacante que roba el token.
- **5b.** Sin el token montado, un contenedor comprometido **no tiene credencial hacia la API server** por defecto, así que no puede enumerar recursos, escalar ni pivotar usando los permisos de la SA. Con un token válido montado, el atacante puede llamar a la API con los permisos de esa ServiceAccount (leer Secrets, crear Pods, etc., según su RBAC): es un vector de escalada directo. `automountServiceAccountToken: false` para cargas que no llaman a la API elimina ese vector.
- **5c.** `expirationSeconds` limita la ventana de validez del token (menor tiempo útil si se filtra). `audience` fija para **qué** servicio es válido el token: un verificador que exige la audiencia `vault` rechazará ese token si alguien intenta reusarlo contra la API server (`https://kubernetes.default.svc`) u otro servicio. Mitiga la **reutilización cruzada** de un token filtrado entre servicios.
- **5d.** La SA `default` la comparten todas las cargas del namespace que no declaran otra: no permite atribuir ni acotar permisos por aplicación, y si alguien le agrega permisos "para que algo funcione", **todas** las cargas del namespace los heredan. Least privilege exige una ServiceAccount dedicada por aplicación, con su propio RBAC mínimo.

### Ejercicio 6

- **6a.** Con `immutable: true`, el kubelet **deja de watchear** ese Secret para detectar cambios (nunca cambiará). En clusters grandes con muchos Pods montando muchos Secrets, esos watches consumen recursos apreciables en el kubelet y en la API server; marcarlos inmutables **reduce esa carga** y mejora la escalabilidad, además de prevenir cambios accidentales o maliciosos.
- **6b.** En Git se guarda el objeto `ExternalSecret`, que solo contiene **referencias** (nombre del store, ruta/clave en el gestor externo) — **no el valor**. El valor real vive en el gestor (Vault, cloud KMS/secret manager) y el operator lo materializa en el cluster en runtime. Así evitás commitear material sensible (aunque sea base64) al historial del repositorio, que es prácticamente imborrable y suele tener acceso amplio.
- **6c.** El External Secrets Operator **crea un `Secret` nativo en etcd**: hereda toda la superficie de los Secrets de Kubernetes (RBAC, encryption at rest, quien pueda leer el objeto lo obtiene). El Secrets Store CSI Driver puede **montar el secreto directo en el Pod** desde el gestor externo **sin persistirlo en etcd** (a menos que actives la sincronización), reduciendo el número de copias del secreto y sacándolo del almacén de etcd — a cambio de acoplar la disponibilidad del Pod al gestor externo.
- **6d.** Porque son controles para **modelos de amenaza distintos**. Encryption at rest protege el almacenamiento de etcd; un Secret commiteado en Git queda expuesto en el **historial del repositorio**, accesible para cualquiera con lectura del repo, clones, forks y CI — un canal que el cifrado de etcd no toca. Un secreto en Git es, a efectos prácticos, un secreto quemado que hay que **rotar**.

</details>