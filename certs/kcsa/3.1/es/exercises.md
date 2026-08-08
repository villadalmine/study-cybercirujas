# Ejercicios guiados — Tema 3.1: Pod Security Standards (KCSA)

> **Objetivo.** Aplicar de forma práctica los tres perfiles de los *Pod Security Standards* (PSS) y el admission controller *Pod Security Admission* (PSA, GA desde Kubernetes v1.25). Terminás sabiendo etiquetar namespaces, leer los mensajes de rechazo del API server, corregir un `securityContext` hasta cumplir `restricted`, y usar `warn`/`audit` para migrar sin romper cargas existentes.
>
> **Prerequisitos.** Un cluster con control plane **v1.25 o superior** (PSA viene habilitado por defecto) y `kubectl` configurado como cluster-admin. Sirve `kind`, `minikube` o cualquier cluster de laboratorio. Verificá:
>
> ```bash
> kubectl version -o json | grep -E 'gitVersion'
> # "gitVersion": "v1.29.x"  (cualquier valor >= v1.25)
> ```

---

## Bloque 1 — Los tres perfiles y dónde vive el control

Los PSS definen **tres perfiles acumulativos** —`privileged`, `baseline`, `restricted`— que son una *especificación* (una lista de campos permitidos/prohibidos en el `PodSpec`). Quien los *hace cumplir* es el admission controller **PodSecurity**, que actúa a nivel de **namespace** leyendo labels.

**Pasos**

1. Confirmá que el admission plugin `PodSecurity` está activo. En un cluster gestionado no ves el flag, pero podés inferirlo probando labels (lo hacés en el Bloque 2). En `kind`/`kubeadm` podés mirar el manifiesto estático del API server:

   ```bash
   grep -i 'enable-admission-plugins' /etc/kubernetes/manifests/kube-apiserver.yaml
   # --enable-admission-plugins=NodeRestriction,PodSecurity,...
   ```

   > Nota: `PodSecurity` está en la lista de plugins habilitados **por defecto**, así que puede no aparecer explícito y aun así estar activo.

2. Creá un namespace limpio de trabajo:

   ```bash
   kubectl create namespace pss-lab
   # namespace/pss-lab created
   ```

3. Revisá que un namespace **sin labels de PSA** no aplica ninguna restricción de *enforce*. El comportamiento por defecto del cluster (si no se configuró un `AdmissionConfiguration`) equivale a `privileged` en `enforce`. Desplegá un Pod deliberadamente privilegiado:

   ```yaml
   # privileged-pod.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: danger
     namespace: pss-lab
   spec:
     containers:
     - name: shell
       image: busybox:1.36
       command: ["sleep", "3600"]
       securityContext:
         privileged: true          # pediría acceso total al host
   ```

   ```bash
   kubectl apply -f privileged-pod.yaml
   # pod/danger created
   ```

   El Pod se crea: sin label `enforce`, PSA no bloquea nada.

4. Limpiá para el próximo bloque:

   ```bash
   kubectl delete pod danger -n pss-lab
   # pod "danger" deleted
   ```

**Preguntas de comprensión**

1. ¿Cuál es la diferencia conceptual entre un *Pod Security Standard* y el *Pod Security Admission controller*?
2. Los tres perfiles son "acumulativos". ¿Qué significa eso exactamente respecto a `baseline` y `restricted`?
3. Un namespace recién creado, sin ningún label, ¿con qué nivel de `enforce` se comporta por defecto y por qué el Pod privilegiado del paso 3 fue admitido?

---

## Bloque 2 — Etiquetar un namespace con `enforce: baseline`

El control se activa con labels de la forma `pod-security.kubernetes.io/<MODE>: <LEVEL>`, donde `<MODE>` ∈ {`enforce`, `audit`, `warn`} y `<LEVEL>` ∈ {`privileged`, `baseline`, `restricted`}.

**Pasos**

1. Aplicá `enforce: baseline` al namespace:

   ```bash
   kubectl label namespace pss-lab \
     pod-security.kubernetes.io/enforce=baseline --overwrite
   # namespace/pss-lab labeled
   ```

2. Verificá los labels:

   ```bash
   kubectl get namespace pss-lab --show-labels
   # NAME      STATUS   AGE   LABELS
   # pss-lab   Active   5m    kubernetes.io/metadata.name=pss-lab,pod-security.kubernetes.io/enforce=baseline
   ```

3. Reintentá el Pod privilegiado del bloque anterior. Ahora `baseline` prohíbe `privileged: true`:

   ```bash
   kubectl apply -f privileged-pod.yaml
   # Error from server (Forbidden): error when creating "privileged-pod.yaml":
   # pods "danger" is forbidden: violates PodSecurity "baseline:latest":
   # privileged (container "shell" must not set securityContext.privileged=true)
   ```

4. Desplegá ahora un Pod que **sí** cumple `baseline` (no pide `privileged`, ni host namespaces, ni `hostPath`, pero corre como root, que `baseline` permite):

   ```yaml
   # baseline-ok.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: baseline-ok
     namespace: pss-lab
   spec:
     containers:
     - name: web
       image: nginx:1.27
       ports:
       - containerPort: 80
   ```

   ```bash
   kubectl apply -f baseline-ok.yaml
   # pod/baseline-ok created
   ```

   Se crea sin problemas: `nginx` por defecto arranca como root, y **`baseline` lo tolera**.

**Preguntas de comprensión**

1. Descomponé el label `pod-security.kubernetes.io/enforce=baseline` en sus tres partes (prefijo, modo, nivel).
2. En el mensaje de error del paso 3 aparece `"baseline:latest"`. ¿Qué representa ese sufijo `:latest`?
3. El Pod `nginx` del paso 4 corre como **root** y aun así lo admite `baseline`. ¿Qué clase de amenazas bloquea `baseline` entonces, si no impide correr como root?

---

## Bloque 3 — `enforce: restricted` y corregir un Pod hasta que cumpla

`restricted` es el perfil de *hardening* fuerte: exige `runAsNonRoot`, `allowPrivilegeEscalation: false`, dropear **todas** las capabilities y declarar un `seccompProfile`. Vamos a ver los cuatro tipos de violación juntos y arreglarlos uno a uno.

**Pasos**

1. Subí el nivel de `enforce` a `restricted`:

   ```bash
   kubectl label namespace pss-lab \
     pod-security.kubernetes.io/enforce=restricted --overwrite
   # namespace/pss-lab labeled
   ```

2. El Pod `baseline-ok` sigue **corriendo** (PSA solo evalúa en *admission*, no expulsa lo ya creado), pero intentá recrearlo y verás el rechazo completo. Primero borralo:

   ```bash
   kubectl delete pod baseline-ok -n pss-lab
   # pod "baseline-ok" deleted
   ```

   ```bash
   kubectl apply -f baseline-ok.yaml
   # Error from server (Forbidden): error when creating "baseline-ok.yaml":
   # pods "baseline-ok" is forbidden: violates PodSecurity "restricted:latest":
   # allowPrivilegeEscalation != false (container "web" must set securityContext.allowPrivilegeEscalation=false),
   # unrestricted capabilities (container "web" must set securityContext.capabilities.drop=["ALL"]),
   # runAsNonRoot != true (pod or container "web" must set securityContext.runAsNonRoot=true),
   # seccompProfile (pod or container "web" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
   ```

   Leé los cuatro requisitos que enumera el error: son exactamente los que `restricted` agrega sobre `baseline`.

3. Construí un Pod que cumpla `restricted`. Usá una imagen que soporte correr como no-root (`nginxinc/nginx-unprivileged` escucha en 8080 sin necesitar root):

   ```yaml
   # restricted-ok.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: restricted-ok
     namespace: pss-lab
   spec:
     securityContext:
       runAsNonRoot: true          # requisito restricted (nivel Pod)
       runAsUser: 101              # usuario no-root de nginx-unprivileged
       seccompProfile:
         type: RuntimeDefault      # requisito restricted
     containers:
     - name: web
       image: nginxinc/nginx-unprivileged:1.27
       ports:
       - containerPort: 8080
       securityContext:
         allowPrivilegeEscalation: false   # requisito restricted
         capabilities:
           drop: ["ALL"]                   # requisito restricted
   ```

   ```bash
   kubectl apply -f restricted-ok.yaml
   # pod/restricted-ok created
   ```

4. Confirmá que arrancó y que efectivamente corre como no-root:

   ```bash
   kubectl get pod restricted-ok -n pss-lab
   # NAME            READY   STATUS    RESTARTS   AGE
   # restricted-ok   1/1     Running   0          15s

   kubectl exec restricted-ok -n pss-lab -- id
   # uid=101(nginx) gid=101(nginx) groups=101(nginx)
   ```

5. **Experimento de diagnóstico:** quitá una sola línea (`capabilities.drop: ["ALL"]`) del manifiesto y volvé a aplicar con `--dry-run=server`, que evalúa el admission **sin crear** el objeto:

   ```bash
   kubectl apply -f restricted-ok.yaml --dry-run=server
   # (con drop:["ALL"] presente) pod/restricted-ok configured (server dry run)
   ```

   `--dry-run=server` es la forma canónica de validar cumplimiento de PSS en un pipeline de CI antes de aplicar de verdad.

**Preguntas de comprensión**

1. El error del paso 2 lista cuatro violaciones. Nombralas y decí en qué nivel (`Pod` vs `container`) se resuelve cada una.
2. ¿Por qué `runAsNonRoot: true` sin especificar `runAsUser` puede aun así fallar en tiempo de *ejecución* con ciertas imágenes, aunque pase el admission?
3. `restricted` permite **una** excepción a "dropear todas las capabilities": ¿cuál capability se puede volver a agregar con `capabilities.add` y para qué sirve?
4. ¿Por qué `--dry-run=server` detecta violaciones de PSS y `--dry-run=client` no?

---

## Bloque 4 — `warn` y `audit`: migrar sin romper producción

En un cluster real no podés poner `enforce: restricted` de golpe: matarías cargas existentes. La estrategia es combinar los tres modos en el mismo namespace y **pinnear la versión** del estándar.

**Pasos**

1. Simulá un namespace de producción que hoy corre en `baseline` pero al que querés migrar a `restricted`. Aplicá los tres modos a la vez:

   ```bash
   kubectl create namespace prod-migracion

   kubectl label namespace prod-migracion \
     pod-security.kubernetes.io/enforce=baseline \
     pod-security.kubernetes.io/enforce-version=v1.29 \
     pod-security.kubernetes.io/warn=restricted \
     pod-security.kubernetes.io/warn-version=v1.29 \
     pod-security.kubernetes.io/audit=restricted \
     pod-security.kubernetes.io/audit-version=v1.29 \
     --overwrite
   # namespace/prod-migracion labeled
   ```

   Leé esto como: *"hago cumplir `baseline` (nada se rompe), pero **advierto** y **audito** contra `restricted`"*.

2. Desplegá el Pod `nginx` estándar (cumple `baseline`, viola `restricted`):

   ```yaml
   # nginx-prod.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: legacy-web
     namespace: prod-migracion
   spec:
     containers:
     - name: web
       image: nginx:1.27
   ```

   ```bash
   kubectl apply -f nginx-prod.yaml
   # Warning: would violate PodSecurity "restricted:v1.29": allowPrivilegeEscalation != false
   #  (container "web" must set securityContext.allowPrivilegeEscalation=false), unrestricted
   #  capabilities (...), runAsNonRoot != true (...), seccompProfile (...)
   # pod/legacy-web created
   ```

   Observá la diferencia clave con el Bloque 3: el Pod **se crea igual** (`enforce` es `baseline`), pero recibís un `Warning:` visible en la salida del `kubectl` porque `warn=restricted`. Ese warning es lo que verían tus desarrolladores en su CI/CD mientras adaptan los manifiestos.

3. El modo `audit` no aparece en tu terminal: escribe un evento en el **audit log del API server** con la anotación `pod-security.kubernetes.io/audit-violations`. Si tenés acceso al audit log del control plane:

   ```bash
   grep 'audit-violations' /var/log/kubernetes/audit.log | tail -1
   # ..."pod-security.kubernetes.io/audit-violations":"would violate PodSecurity
   #    \"restricted:v1.29\": allowPrivilegeEscalation != false ..."...
   ```

   `audit` alimenta tu SIEM sin molestar a nadie; `warn` educa al usuario en el momento; `enforce` bloquea. Los tres son independientes y pueden apuntar a niveles distintos.

4. Cuando todos los manifiestos ya cumplen `restricted`, cerrás la migración subiendo `enforce`:

   ```bash
   kubectl label namespace prod-migracion \
     pod-security.kubernetes.io/enforce=restricted --overwrite
   ```

**Preguntas de comprensión**

1. Explicá en una frase qué hace cada uno de los tres modos: `enforce`, `warn`, `audit`.
2. En el paso 2 el Pod se creó a pesar de violar `restricted`. ¿Qué label determinó que **no** se bloqueara?
3. ¿Para qué sirve fijar `*-version=v1.29` en vez de dejar que el nivel se evalúe contra `latest`? ¿Qué problema de estabilidad previene?
4. Diseñás la migración de 200 namespaces a `restricted`. ¿En qué orden aplicarías los modos y por qué `audit`/`warn` van antes que `enforce`?

---

## Bloque 5 — Exemptions y límites del control

PSA tiene *exemptions* configuradas a nivel de cluster (no por namespace) en el objeto `AdmissionConfiguration`, y tiene un límite importante: **solo evalúa el `PodSpec` en admission**, no el runtime ni recursos que crean Pods indirectamente.

**Pasos**

1. Entendé qué se puede exceptuar. En el `AdmissionConfiguration` del API server, el plugin `PodSecurity` acepta `exemptions` por `usernames`, `runtimeClasses` y `namespaces`. Ejemplo de configuración del control plane (esto lo define el operador del cluster, **no** se puede setear con un simple label):

   ```yaml
   # /etc/kubernetes/admission/pod-security.yaml
   apiVersion: apiserver.config.k8s.io/v1
   kind: AdmissionConfiguration
   plugins:
   - name: PodSecurity
     configuration:
       apiVersion: pod-security.admission.config.k8s.io/v1
       kind: PodSecurityConfiguration
       defaults:                       # nivel por defecto para namespaces SIN labels
         enforce: "baseline"
         enforce-version: "latest"
         audit: "restricted"
         warn: "restricted"
       exemptions:
         usernames: []
         runtimeClasses: []
         namespaces: ["kube-system"]   # los componentes del sistema quedan exentos
   ```

   > Punto clave de seguridad: `namespaces: ["kube-system"]` exime por completo a `kube-system`. Nunca corras cargas de usuario ahí: heredan una exención total de PSA.

2. Comprobá el **límite de granularidad**. PSA es *namespace-scoped*: no podés eximir un solo Pod de un namespace con `enforce: restricted`. Si un CronJob del sistema necesita `hostPath`, la única salida es moverlo a un namespace con `enforce` más laxo, o usar los mecanismos de exemption de arriba.

3. Verificá el **límite de "admission-time"**. Creá un Deployment (no un Pod) que viole `restricted` en el namespace `pss-lab`:

   ```bash
   kubectl create deployment bad -n pss-lab --image=nginx:1.27
   # deployment.apps/bad created
   ```

   El **Deployment se crea** (el `Deployment` no es un Pod), pero el `ReplicaSet` no logra crear el Pod. Miralo:

   ```bash
   kubectl get deploy,rs,pod -n pss-lab -l app=bad
   # NAME                  READY   UP-TO-DATE   AVAILABLE
   # deployment.apps/bad   0/1     0            0

   kubectl get events -n pss-lab --field-selector reason=FailedCreate
   # LAST SEEN   TYPE      REASON         OBJECT                MESSAGE
   # 10s         Warning   FailedCreate   replicaset/bad-xxxx   Error creating: pods "bad-xxxx"
   #   is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false, ...
   ```

   Lección de diagnóstico: cuando un Deployment queda en `0/1` sin Pods y sin errores obvios en el Deployment, **el rechazo de PSA aparece en los events del ReplicaSet**, no en el Deployment ni en el `kubectl apply`. Es el modo de falla más confuso de PSS en producción.

4. Limpiá el laboratorio:

   ```bash
   kubectl delete namespace pss-lab prod-migracion
   # namespace "pss-lab" deleted
   # namespace "prod-migracion" deleted
   ```

**Preguntas de comprensión**

1. Nombrá las tres dimensiones por las que PSA permite configurar `exemptions` en el `AdmissionConfiguration`.
2. ¿Por qué es un riesgo de seguridad correr cargas de usuario en un namespace exento como `kube-system`?
3. Un Deployment queda en `0/1 READY` pero `kubectl apply` no dio ningún error. ¿Dónde buscás el mensaje de rechazo de PSS y por qué no apareció en el `apply`?
4. PSS **no** protege contra explotación en tiempo de ejecución (p. ej. un escape del kernel una vez que el contenedor ya corre). ¿Qué controles complementarios cubren ese hueco que PSS deja abierto?

---

## Respuestas

<details>
<summary>Mostrar / ocultar soluciones</summary>

### Bloque 1

1. Un **Pod Security Standard** es una *especificación* declarativa: define qué campos del `PodSpec` están permitidos o prohibidos en cada uno de los tres perfiles (`privileged`, `baseline`, `restricted`). Es solo texto/política, no ejecuta nada. El **Pod Security Admission controller** (`PodSecurity`) es el *validating admission controller* incorporado al API server que **hace cumplir** esos estándares interceptando las peticiones de creación/actualización de Pods según los labels del namespace.
2. "Acumulativos" significa que cada perfil es un superconjunto de restricciones del anterior: `baseline` prohíbe las escaladas de privilegio *conocidas* sobre `privileged`, y `restricted` añade **todas** las restricciones de `baseline` **más** las de hardening (non-root, drop capabilities, seccomp, no privilege-escalation). Cumplir `restricted` implica cumplir `baseline`.
3. Se comporta como **`privileged`** (el nivel más permisivo) por defecto, salvo que el operador haya definido otros `defaults` en el `AdmissionConfiguration`. Como no había label `enforce`, PSA no evalúa nada y el Pod privilegiado fue admitido.

### Bloque 2

1. Prefijo: `pod-security.kubernetes.io/` · Modo: `enforce` · Nivel: `baseline`. Formato general: `pod-security.kubernetes.io/<MODE>=<LEVEL>`.
2. `:latest` es la **versión del estándar** contra la que se evalúa. Al no fijar `enforce-version`, PSA usa la definición del perfil correspondiente a la versión más reciente que conoce el API server. Fijar una versión (`v1.29`) congela las reglas para que un upgrade del cluster no cambie silenciosamente qué se acepta.
3. `baseline` bloquea las **escaladas de privilegio conocidas**: contenedores `privileged`, host namespaces (`hostNetwork`, `hostPID`, `hostIPC`), volúmenes `hostPath`, `hostPort`, capabilities peligrosas fuera del set por defecto, `/proc` sin enmascarar, etc. **No** exige correr como no-root; ese requisito pertenece a `restricted`. Por eso `nginx` como root pasa `baseline`.

### Bloque 3

1. Las cuatro violaciones:
   - `allowPrivilegeEscalation != false` → nivel **container** (`securityContext.allowPrivilegeEscalation: false`).
   - `unrestricted capabilities` → nivel **container** (`securityContext.capabilities.drop: ["ALL"]`).
   - `runAsNonRoot != true` → nivel **Pod o container** (`securityContext.runAsNonRoot: true`).
   - `seccompProfile` → nivel **Pod o container** (`securityContext.seccompProfile.type: RuntimeDefault` o `Localhost`).
2. `runAsNonRoot: true` solo le dice al kubelet que **rechace en runtime** si el UID resuelto es 0; no *fuerza* un UID. Si la imagen tiene `USER root`/UID 0 y no especificás `runAsUser` distinto de 0, el admission puede pasar pero el kubelet aborta el arranque con `CreateContainerConfigError` ("container has runAsNonRoot and image will run as root"). Por eso conviene fijar además `runAsUser` a un UID no-root que la imagen soporte.
3. **`NET_BIND_SERVICE`**. `restricted` permite `capabilities.add: ["NET_BIND_SERVICE"]` para que un proceso no-root pueda enlazar puertos privilegiados (<1024) sin necesitar más privilegios. Todo lo demás debe seguir dropeado (`drop: ["ALL"]`).
4. `--dry-run=server` envía la petición al API server, que **ejecuta la cadena de admission** (incluido `PodSecurity`) y devuelve el veredicto sin persistir el objeto. `--dry-run=client` solo valida el YAML localmente en `kubectl` y nunca contacta el admission controller, así que no puede ver violaciones de PSS.

### Bloque 4

1. `enforce` **bloquea** la creación del Pod si viola el nivel; `warn` **admite** pero devuelve un `Warning:` al usuario en la respuesta del API; `audit` **admite** silenciosamente pero anota la violación en el **audit log** del API server.
2. El label **`pod-security.kubernetes.io/enforce=baseline`**. Como el Pod cumple `baseline`, `enforce` lo admite; `warn`/`audit=restricted` solo generan advertencia y evento, no bloquean.
3. Fijar `*-version=v1.29` congela **qué reglas** definen el perfil. Los perfiles evolucionan entre releases (se agregan campos controlados); si dejás `latest`, un upgrade del control plane puede empezar a rechazar Pods que antes pasaban, rompiendo cargas sin cambio de tu parte. Pinnear la versión hace la política determinista y desacopla el hardening del ciclo de upgrades.
4. Orden recomendado: primero `audit` (y opcionalmente `warn`) apuntando al nivel destino, **manteniendo `enforce` en el nivel actual**; observás violaciones en logs/SIEM y avisás a los equipos; corregís manifiestos; y **solo al final** subís `enforce` al nivel destino. `audit`/`warn` van primero porque no interrumpen el servicio: te dan visibilidad del blast radius antes de bloquear nada.

### Bloque 5

1. `usernames`, `runtimeClasses` y `namespaces`. Se definen en el `PodSecurityConfiguration` dentro del `AdmissionConfiguration`, a nivel de cluster.
2. Un namespace exento **no evalúa ningún perfil**, así que cualquier Pod ahí puede ser `privileged`, usar `hostPath`, host namespaces, etc., sin restricción. Correr cargas de usuario en `kube-system` (o cualquier namespace exento) les da de facto una vía a privilegios de nodo/host y anula por completo la protección de PSS. Las cargas de usuario deben vivir en namespaces con su propia política de `enforce`.
3. En los **events del ReplicaSet** (`reason=FailedCreate`), no en el Deployment ni en el `kubectl apply`. El `apply` solo creó el objeto `Deployment`, que no es un Pod y por eso no dispara PSA; el rechazo ocurre después, cuando el `ReplicaSet` controller intenta crear el Pod y el admission lo bloquea, dejando el Deployment en `0/N` sin Pods.
4. Controles de runtime y de aislamiento complementarios: **seccomp/AppArmor/SELinux** (confinamiento del kernel), **runtimes con sandbox** como gVisor o Kata Containers (`RuntimeClass`), **NetworkPolicies** (limitar el blast radius de red), **detección en runtime** tipo Falco/Tetragon, y **RBAC** mínimo. PSS solo restringe el `PodSpec` en admission; no observa ni contiene lo que hace el proceso una vez en ejecución.

</details>

---

**Fuentes**

- CNCF — *KCSA Curriculum* (dominio *Kubernetes Cluster Component Security* / *Platform Security*): https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
- Kubernetes — *Pod Security Standards*: https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Kubernetes — *Pod Security Admission*: https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Kubernetes — *Enforce Pod Security Standards with Namespace Labels*: https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-namespace-labels/
- Kubernetes — *Enforce Pod Security Standards by Configuring the Built-in Admission Controller* (exemptions y `AdmissionConfiguration`): https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-admission-controller/
- Kubernetes — *Admission Controllers Reference · PodSecurity*: https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#podsecurity