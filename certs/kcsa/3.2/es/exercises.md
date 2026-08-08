# Ejercicios Guiados — Tema 3.2: Pod Security Admission (PSA)

> **Certificación:** KCSA — Kubernetes and Cloud Native Security Associate
> **Peso en el examen:** 3.14
> **Fuente de referencia:** [KCSA Curriculum (CNCF)](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
> **Documentación oficial:** [Pod Security Admission](https://kubernetes.io/docs/concepts/security/pod-security-admission/) · [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/) · [Enforce Standards with Namespace Labels](https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-namespace-labels/)

---

## Preparación del entorno

Estos ejercicios asumen un clúster Kubernetes **v1.25 o superior**, donde Pod Security Admission está habilitado por defecto (GA desde 1.25). Un `kind` o `minikube` reciente sirve perfectamente.

```bash
# Verificá la versión del server: PSA es GA a partir de 1.25
kubectl version -o json | grep -A3 serverVersion
```

Salida esperada (los valores exactos varían):

```json
  "serverVersion": {
    "major": "1",
    "minor": "29",
    "gitVersion": "v1.29.2",
```

> Si el `minor` es `24` o menor, PSA no está disponible o no es GA; los `labels` de este ejercicio no tendrán efecto y deberías usar un clúster más nuevo.

---

## Ejercicio 1 — Entender los tres niveles y los tres modos

Pod Security Admission es un **admission controller** integrado en el `kube-apiserver` que aplica los **Pod Security Standards (PSS)** a nivel de **namespace** mediante *labels*. No usa objetos como el difunto `PodSecurityPolicy`: se configura declarativamente con labels sobre el namespace.

Los tres **niveles** (policies) son:

| Nivel | Qué permite |
|---|---|
| `privileged` | Sin restricciones. Permite escalada de privilegios conocida. |
| `baseline` | Mínimamente restrictivo. Bloquea escaladas de privilegios conocidas (privileged, hostNetwork, hostPID, etc.). |
| `restricted` | Fuertemente restrictivo. Sigue las mejores prácticas de hardening de pods. |

Los tres **modos** son:

| Modo | Efecto cuando el pod viola la policy |
|---|---|
| `enforce` | **Rechaza** la creación del pod. |
| `audit` | Permite el pod, pero registra una **entrada de auditoría** en el audit log. |
| `warn` | Permite el pod, pero devuelve un **warning** visible al usuario en `kubectl`. |

El formato del label es:

```
pod-security.kubernetes.io/<MODO>: <NIVEL>
pod-security.kubernetes.io/<MODO>-version: <VERSIÓN|latest>
```

### Pasos

1. Creá un namespace de laboratorio limpio:

   ```bash
   kubectl create namespace psa-lab
   ```

   ```
   namespace/psa-lab created
   ```

2. Inspeccioná sus labels iniciales. Por defecto un namespace nuevo **no** trae labels de PSA (salvo que un cluster admin haya configurado un `AdmissionConfiguration` global por defecto):

   ```bash
   kubectl get namespace psa-lab --show-labels
   ```

   ```
   NAME      STATUS   AGE   LABELS
   psa-lab   Active   5s    kubernetes.io/metadata.name=psa-lab
   ```

3. Desplegá un pod deliberadamente peligroso (privilegiado) para confirmar que, **sin labels**, se admite sin problemas:

   ```bash
   kubectl -n psa-lab run priv-pod --image=nginx:1.27 \
     --overrides='{"spec":{"containers":[{"name":"c","image":"nginx:1.27","securityContext":{"privileged":true}}]}}'
   ```

   ```
   pod/priv-pod created
   ```

4. Limpiá el pod antes de continuar:

   ```bash
   kubectl -n psa-lab delete pod priv-pod
   ```

### Preguntas de verificación (bloque 1)

1. ¿Sobre qué objeto de Kubernetes se aplican los labels de Pod Security Admission: el pod, el deployment o el namespace?
2. Un pod viola la policy `restricted` en un namespace etiquetado con `warn=restricted` (y ningún otro label). ¿Se crea el pod? ¿Qué ve el usuario?
3. ¿Cuál de los tres niveles bloquea `hostNetwork: true` y cuál lo permite?
4. En el paso 3, ¿por qué se admitió un pod privilegiado sin quejas del admission controller?

---

## Ejercicio 2 — Aplicar `enforce=baseline` y ver un rechazo real

Ahora vamos a activar el modo bloqueante y comprobar que PSA **rechaza** cargas de trabajo peligrosas.

### Pasos

1. Etiquetá el namespace para **rechazar** todo lo que viole `baseline`:

   ```bash
   kubectl label namespace psa-lab \
     pod-security.kubernetes.io/enforce=baseline \
     pod-security.kubernetes.io/enforce-version=v1.29
   ```

   ```
   namespace/psa-lab labeled
   ```

   > **Buena práctica:** fijá siempre `enforce-version` a una versión concreta (ej. `v1.29`) en lugar de `latest`. Con `latest`, un upgrade del clúster puede endurecer silenciosamente las reglas y romper cargas que antes pasaban. Fijar la versión hace la policy determinista y reproducible.

2. Intentá crear de nuevo el pod privilegiado:

   ```bash
   kubectl -n psa-lab run priv-pod --image=nginx:1.27 \
     --overrides='{"spec":{"containers":[{"name":"c","image":"nginx:1.27","securityContext":{"privileged":true}}]}}'
   ```

   Salida esperada (rechazo):

   ```
   Error from server (Forbidden): pods "priv-pod" is forbidden: violates PodSecurity "baseline:v1.29": privileged (container "c" must not set securityContext.privileged=true)
   ```

3. Creá ahora un pod que **cumpla** `baseline` (un nginx normal, sin privilegios):

   ```bash
   kubectl -n psa-lab run ok-pod --image=nginx:1.27
   ```

   ```
   pod/ok-pod created
   ```

4. Confirmá que ese pod cumple, pero **no** cumpliría `restricted`. Reetiquetá para que además **avise** (`warn`) sobre `restricted` sin bloquear:

   ```bash
   kubectl label namespace psa-lab \
     pod-security.kubernetes.io/warn=restricted \
     pod-security.kubernetes.io/warn-version=v1.29
   ```

5. Borrá y recreá el pod nginx normal para disparar el chequeo de admisión otra vez:

   ```bash
   kubectl -n psa-lab delete pod ok-pod
   kubectl -n psa-lab run ok-pod --image=nginx:1.27
   ```

   Salida esperada (el pod se crea, pero con warnings de `restricted`):

   ```
   Warning: would violate PodSecurity "restricted:v1.29": allowPrivilegeEscalation != false (container "ok-pod" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "ok-pod" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "ok-pod" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "ok-pod" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
   pod/ok-pod created
   ```

### Preguntas de verificación (bloque 2)

1. En el mensaje de error del paso 2, ¿qué parte indica el **nivel y la versión** que se está aplicando?
2. El pod del paso 3 pasó `enforce=baseline` pero disparó warnings de `restricted` en el paso 5. ¿Es contradictorio? Explicá la relación entre ambos niveles.
3. Enumerá las cuatro exigencias de `restricted` que aparecen en los warnings del paso 5 y qué campo del `securityContext` satisface cada una.
4. ¿Por qué se recomienda fijar `enforce-version=v1.29` en lugar de `latest`?
5. Un mismo namespace, ¿puede tener a la vez `enforce=baseline`, `audit=restricted` y `warn=restricted`? ¿Qué caso de uso resuelve esa combinación?

---

## Ejercicio 3 — Escribir un pod que cumpla `restricted`

El objetivo aquí es construir el `securityContext` mínimo que satisface el nivel más estricto, y ver que PSA lo admite sin un solo warning.

### Pasos

1. Endurecé el namespace: ahora `enforce=restricted`:

   ```bash
   kubectl label namespace psa-lab --overwrite \
     pod-security.kubernetes.io/enforce=restricted \
     pod-security.kubernetes.io/enforce-version=v1.29
   ```

   > El flag `--overwrite` es necesario porque el label `enforce` ya existía (`baseline`) del ejercicio anterior.

2. Confirmá que el `ok-pod` anterior ya **no** podría crearse ahora. Borralo e intentá recrearlo:

   ```bash
   kubectl -n psa-lab delete pod ok-pod
   kubectl -n psa-lab run ok-pod --image=nginx:1.27
   ```

   Salida esperada (ahora sí rechaza, no solo avisa):

   ```
   Error from server (Forbidden): pods "ok-pod" is forbidden: violates PodSecurity "restricted:v1.29": allowPrivilegeEscalation != false (container "ok-pod" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "ok-pod" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "ok-pod" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "ok-pod" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
   ```

3. Escribí un manifiesto que **sí** cumpla `restricted`. Guardalo como `restricted-pod.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: restricted-pod
     namespace: psa-lab
   spec:
     securityContext:
       runAsNonRoot: true
       runAsUser: 1000
       seccompProfile:
         type: RuntimeDefault
     containers:
       - name: app
         image: nginxinc/nginx-unprivileged:1.27
         ports:
           - containerPort: 8080
         securityContext:
           allowPrivilegeEscalation: false
           capabilities:
             drop: ["ALL"]
   ```

   > Nota: usamos `nginxinc/nginx-unprivileged` porque el nginx oficial escucha en el puerto 80 y arranca como root; la variante *unprivileged* corre como usuario no-root en el 8080, coherente con `runAsNonRoot: true`.

4. Aplicá el manifiesto:

   ```bash
   kubectl apply -f restricted-pod.yaml
   ```

   Salida esperada (sin warnings, sin errores):

   ```
   pod/restricted-pod created
   ```

5. Verificá que corre:

   ```bash
   kubectl -n psa-lab get pod restricted-pod
   ```

   ```
   NAME             READY   STATUS    RESTARTS   AGE
   restricted-pod   1/1     Running   0          15s
   ```

### Preguntas de verificación (bloque 3)

1. En el manifiesto del paso 3, ¿qué controles van en el `securityContext` a **nivel de pod** y cuáles a **nivel de contenedor**? ¿Por qué esa distribución?
2. Si quitaras `seccompProfile.type: RuntimeDefault`, ¿qué modo de PSA (enforce/audit/warn) determina si el pod se crea igual o se rechaza?
3. ¿Por qué `capabilities.drop: ["ALL"]` es un requisito de `restricted` pero no de `baseline`?
4. ¿Qué diferencia práctica hay entre `runAsNonRoot: true` y `runAsUser: 1000`? ¿Cuál de los dos exige estrictamente el nivel `restricted`?

---

## Ejercicio 4 — Exenciones (exemptions) y el default a nivel de clúster

PSA se puede configurar globalmente mediante un archivo `AdmissionConfiguration` pasado al `kube-apiserver`. Ahí se definen los **defaults** que aplican a namespaces sin labels, y las **exemptions** (por `usernames`, `runtimeClassNames` o `namespaces`). Los namespaces exentos **saltean por completo** los chequeos de PSA.

> En un `kind`/`minikube` no siempre podés editar los flags del apiserver cómodamente; este ejercicio es principalmente de lectura y comprensión, con una parte práctica opcional.

### Pasos

1. Estudiá esta configuración de ejemplo (`admission-config.yaml`), que un cluster admin montaría en el nodo del control plane y referenciaría con `--admission-control-config-file`:

   ```yaml
   apiVersion: apiserver.config.k8s.io/v1
   kind: AdmissionConfiguration
   plugins:
     - name: PodSecurity
       configuration:
         apiVersion: pod-security.admission.config.k8s.io/v1
         kind: PodSecurityConfiguration
         # Defaults aplicados a TODO namespace sin labels propios
         defaults:
           enforce: "baseline"
           enforce-version: "latest"
           audit: "restricted"
           audit-version: "latest"
           warn: "restricted"
           warn-version: "latest"
         # Exenciones: estos NO pasan por PSA en absoluto
         exemptions:
           usernames: []
           runtimeClassNames: []
           namespaces: ["kube-system"]
   ```

2. Observá que `kube-system` está en `exemptions.namespaces`. Esto es deliberado: los componentes del control plane suelen necesitar pods privilegiados (CNI, kube-proxy, etc.). Confirmá que en tu clúster corren cargas privilegiadas ahí:

   ```bash
   kubectl -n kube-system get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | head
   ```

   ```
   coredns-5d78c9869d-abcde
   etcd-kind-control-plane
   kube-apiserver-kind-control-plane
   kube-proxy-xz12k
   ...
   ```

3. Comprobá la diferencia entre **default de clúster** y **label de namespace**: el label del namespace **siempre gana** sobre el default. Aplicá un label `privileged` a `psa-lab` que anula cualquier default más estricto:

   ```bash
   kubectl label namespace psa-lab --overwrite \
     pod-security.kubernetes.io/enforce=privileged
   ```

   ```
   namespace/psa-lab labeled
   ```

4. Verificá que ahora un pod privilegiado vuelve a admitirse en `psa-lab`, pese a cualquier default de clúster más estricto:

   ```bash
   kubectl -n psa-lab run priv-again --image=nginx:1.27 \
     --overrides='{"spec":{"containers":[{"name":"c","image":"nginx:1.27","securityContext":{"privileged":true}}]}}'
   ```

   ```
   pod/priv-again created
   ```

### Preguntas de verificación (bloque 4)

1. Un namespace exento (por estar en `exemptions.namespaces`) tiene además el label `enforce=restricted`. ¿Se aplica `restricted`? ¿Por qué?
2. ¿Qué tres tipos de exención permite el `PodSecurityConfiguration`? Dá un caso de uso legítimo para cada uno.
3. Precedencia: si el default de clúster es `enforce=restricted` y el namespace tiene el label `enforce=privileged`, ¿qué gana? ¿Y por qué eso es un riesgo de seguridad que hay que auditar?
4. ¿Por qué exentar `kube-system` es a la vez necesario y peligroso? ¿Qué mitigación existe?

---

## Ejercicio 5 — Detectar violaciones ANTES de endurecer (`--dry-run` a nivel namespace)

Endurecer un namespace en producción sin saber qué se va a romper es una receta para un incidente. PSA permite un **dry-run** de `enforce` sobre un namespace ya poblado: al aplicar el label con `--dry-run=server`, el apiserver evalúa **todos los pods existentes** contra la policy propuesta y devuelve los warnings, **sin** persistir el label.

### Pasos

1. Creá un namespace con cargas mixtas (una que cumple, una que no):

   ```bash
   kubectl create namespace psa-migrate
   kubectl -n psa-migrate run legacy --image=nginx:1.27
   kubectl -n psa-migrate apply -f restricted-pod.yaml --dry-run=client -o yaml \
     | sed 's/psa-lab/psa-migrate/; s/restricted-pod/modern/' \
     | kubectl apply -f -
   ```

2. **Sin** comprometerte todavía, simulá aplicar `enforce=restricted` con dry-run del server:

   ```bash
   kubectl label --dry-run=server namespace psa-migrate \
     pod-security.kubernetes.io/enforce=restricted \
     pod-security.kubernetes.io/enforce-version=v1.29
   ```

   Salida esperada (el apiserver evalúa los pods vivos y reporta cuáles violarían la policy):

   ```
   Warning: existing pods in namespace "psa-migrate" violate the new PodSecurity enforce level "restricted:v1.29"
   Warning: legacy: allowPrivilegeEscalation != false, unrestricted capabilities, runAsNonRoot != true, seccompProfile
   namespace/psa-migrate labeled (server dry run)
   ```

3. Fijate que el label **no** quedó aplicado (era dry-run). Confirmalo:

   ```bash
   kubectl get namespace psa-migrate -o jsonpath='{.metadata.labels}' ; echo
   ```

   ```
   {"kubernetes.io/metadata.name":"psa-migrate"}
   ```

4. Ahora sabés exactamente qué pod (`legacy`) romperías. El flujo de migración seguro es: primero `warn` + `audit` (no bloqueante) para descubrir violaciones en el tiempo, corregir las cargas, y **recién después** `enforce`. Aplicá la fase no bloqueante:

   ```bash
   kubectl label namespace psa-migrate \
     pod-security.kubernetes.io/warn=restricted \
     pod-security.kubernetes.io/audit=restricted \
     pod-security.kubernetes.io/warn-version=v1.29 \
     pod-security.kubernetes.io/audit-version=v1.29
   ```

   ```
   namespace/psa-migrate labeled
   ```

### Preguntas de verificación (bloque 5)

1. ¿Qué hace exactamente `kubectl label --dry-run=server` sobre un namespace poblado, y por qué es distinto de `--dry-run=client`?
2. Describí el flujo de migración recomendado en tres fases hacia `enforce=restricted`. ¿Por qué no se salta directo a `enforce`?
3. El modo `audit` registra violaciones. ¿Dónde aparecen esas entradas y qué se necesita tener habilitado en el clúster para verlas?
4. Un pod que **ya está corriendo** cuando aplicás `enforce=restricted` con label real (no dry-run): ¿lo mata PSA? ¿En qué momento se aplica realmente la restricción de enforce?

---

## Limpieza

```bash
kubectl delete namespace psa-lab psa-migrate
rm -f restricted-pod.yaml
```

---

## Respuestas

<details>
<summary>Mostrar respuestas de todos los bloques</summary>

### Bloque 1

1. Sobre el **namespace**. PSA lee los labels `pod-security.kubernetes.io/<modo>` del namespace y aplica la policy a todos los pods que se crean/actualizan en él. No se etiqueta ni el pod ni el deployment.
2. **Sí se crea.** El modo `warn` nunca bloquea: solo devuelve un mensaje de advertencia visible en la salida de `kubectl`. El pod queda en estado normal; el usuario ve una línea `Warning: would violate PodSecurity "restricted:..."`.
3. `baseline` **bloquea** `hostNetwork: true` (es una de las escaladas de privilegio conocidas que prohíbe). `privileged` lo **permite**, porque no impone ninguna restricción. (`restricted` también lo bloquea, siendo un superconjunto de las restricciones de `baseline`.)
4. Porque el namespace no tenía **ningún** label de PSA y el clúster no tenía un default más estricto configurado. Sin labels y sin default, PSA se comporta como `privileged`: no aplica ninguna restricción.

### Bloque 2

1. La cadena `"baseline:v1.29"` — formato `<nivel>:<versión>`. Indica que se evaluó contra el nivel `baseline` con las reglas de la versión `v1.29`.
2. No es contradictorio. Los niveles son **acumulativos/anidados**: `restricted` ⊃ `baseline` ⊃ `privileged`. Un pod puede cumplir `baseline` (no hace nada abiertamente peligroso) y aun así no cumplir `restricted` (no aplica el hardening completo). `enforce=baseline` lo dejó pasar; `warn=restricted` avisa que le falta el hardening extra.
3. (1) `allowPrivilegeEscalation != false` → `securityContext.allowPrivilegeEscalation: false` (contenedor). (2) `unrestricted capabilities` → `securityContext.capabilities.drop: ["ALL"]` (contenedor). (3) `runAsNonRoot != true` → `securityContext.runAsNonRoot: true` (pod o contenedor). (4) `seccompProfile` → `securityContext.seccompProfile.type: RuntimeDefault` (o `Localhost`) (pod o contenedor).
4. Porque `latest` sigue la versión del clúster: un upgrade puede endurecer las reglas de un nivel y romper silenciosamente cargas que antes pasaban. Fijar `v1.29` hace la policy **determinista y reproducible**; el endurecimiento se vuelve una decisión explícita (subir la versión), no un efecto colateral de un upgrade.
5. **Sí**, es una práctica recomendada. Ejemplo: `enforce=baseline` bloquea lo francamente peligroso hoy, mientras `warn=restricted` + `audit=restricted` reportan (sin bloquear) qué le falta a las cargas para llegar a `restricted`. Es el patrón de migración progresiva: hacés cumplir un nivel y observás el siguiente.

### Bloque 3

1. **Nivel de pod:** `runAsNonRoot`, `runAsUser`, `seccompProfile` — aplican como default a todos los contenedores del pod y algunos (como `runAsNonRoot`/`seccompProfile`) `restricted` los acepta en cualquiera de los dos niveles. **Nivel de contenedor:** `allowPrivilegeEscalation: false` y `capabilities.drop: ["ALL"]` — deben estar en cada contenedor porque son propiedades intrínsecas del proceso del contenedor. La distribución evita repetir en cada contenedor lo que puede fijarse una vez a nivel pod, dejando en el contenedor lo que PSA exige explícitamente por contenedor.
2. El modo **`enforce`**. Con `enforce=restricted`, quitar `seccompProfile` hace que el pod sea **rechazado**. Con solo `audit`/`warn`, el pod se crearía igual (con una entrada de auditoría o un warning respectivamente).
3. Porque `capabilities.drop: ["ALL"]` implementa el principio de **mínimo privilegio**: quita todas las Linux capabilities y obliga a re-agregar solo las imprescindibles. `baseline` solo prohíbe agregar capabilities peligrosas (un conjunto denylist), pero no exige descartarlas todas; `restricted` sí lo exige (allowlist vacía por defecto), que es hardening real más allá de "no hacer nada peligroso".
4. `runAsNonRoot: true` es una **aserción/validación**: el kubelet verifica en runtime que el UID efectivo no sea 0 y falla el arranque si lo es, pero no fija qué UID usar. `runAsUser: 1000` **impone** un UID concreto. `restricted` exige estrictamente `runAsNonRoot: true` (o equivalente); `runAsUser` es opcional (no debe ser 0, pero no hace falta declararlo si la imagen ya corre como no-root).

### Bloque 4

1. **No se aplica `restricted`.** Una exención hace que PSA **saltee por completo** la evaluación de ese namespace, sin importar sus labels. La exención tiene prioridad sobre cualquier label de modo. (Por eso las exenciones son peligrosas: anulan silenciosamente los controles.)
2. Los tres tipos son: **`usernames`** (identidades que quedan exentas — p.ej. un ServiceAccount de un operador de infraestructura que legítimamente crea pods privilegiados), **`runtimeClassNames`** (p.ej. una `RuntimeClass` sandbox como gVisor/Kata donde el aislamiento ya lo da el runtime), y **`namespaces`** (p.ej. `kube-system`, donde corren componentes del control plane que requieren privilegios).
3. Gana el **label del namespace** (`privileged`). El default de clúster solo aplica a namespaces **sin** ese label; un label explícito siempre lo sobreescribe. El riesgo: cualquiera con permiso para etiquetar namespaces (`update` sobre `namespaces`) puede **degradar** la policy de `restricted` a `privileged` y evadir todo el hardening. Por eso hay que auditar quién puede modificar labels de namespaces (RBAC) y monitorear cambios en labels `pod-security.kubernetes.io/*`.
4. **Necesario** porque los pods del control plane (CNI, kube-proxy, etcd) requieren privilegios que `baseline`/`restricted` prohibirían, y bloquearlos rompería el clúster. **Peligroso** porque un atacante que consiga desplegar en `kube-system` evade PSA por completo. **Mitigación:** restringir fuertemente con RBAC quién puede crear pods en `kube-system`, y complementar PSA con una policy engine externa (Kyverno / OPA Gatekeeper) que sí pueda aplicar reglas dentro de namespaces exentos de PSA.

### Bloque 5

1. `--dry-run=server` envía la petición al **apiserver**, que evalúa todos los pods existentes del namespace contra la policy propuesta y **devuelve los warnings de las violaciones**, pero **no persiste** el label. `--dry-run=client` solo valida el objeto localmente en `kubectl` y **no consulta** al apiserver, así que **no** detecta violaciones de pods existentes. Para saber qué romperías, necesitás `=server`.
2. Tres fases: **(1) `warn` + `audit`** al nivel objetivo (no bloqueante) para descubrir todas las violaciones sin interrumpir cargas; **(2) remediar** las cargas que aparecen en los warnings/audit; **(3) `enforce`** al nivel objetivo, ya con la certeza de que nada se rompe. No se salta a `enforce` directo porque bloquearía recreaciones/rollouts de cargas legítimas todavía no adaptadas, causando un outage.
3. Las entradas de `audit` aparecen en el **audit log del apiserver** (registros de auditoría), como anotaciones `pod-security.kubernetes.io/audit-violations`. Para verlas se necesita tener habilitada la **audit policy** del apiserver (`--audit-policy-file` y un backend de logs/webhook). Sin auditoría configurada en el clúster, el modo `audit` no produce salida observable.
4. **No lo mata.** El enforce de PSA es un **admission controller**: solo actúa en operaciones de **create/update** de pods. Un pod ya corriendo sigue vivo aunque viole la nueva policy. La restricción se aplica recién cuando ese pod se **recrea** (p.ej. un rollout, el reschedule tras la caída de un nodo, o un `delete` + `create`). Por eso el modo `warn`/`audit` es clave: revela las violaciones latentes antes de que un evento de recreación las convierta en fallos.

</details>