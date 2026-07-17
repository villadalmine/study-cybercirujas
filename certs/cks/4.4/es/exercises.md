# CKS 4.4 — Static Analysis of User Workloads and Container Images

El static analysis es un control de tipo "shift-left": se analizan manifiestos YAML (y en algunos casos Dockerfiles/imágenes) **antes** de que lleguen al API server, buscando configuraciones inseguras (contenedores `privileged`, falta de `resources.limits`, `hostPath`/`hostNetwork`/`hostPID`, ausencia de `securityContext`, etc.). A diferencia de herramientas de runtime como Falco, acá no hay un cluster corriendo el workload: se evalúa el YAML como texto/estructura contra un set de reglas. Las dos herramientas de referencia del curriculum son **Kubesec** (scoring ponderado de un objeto) y **KubeLinter** (linter pass/fail con checks configurables), pensadas para integrarse en pipelines de CI/CD como gate previo al `kubectl apply`.

Fuente: [CKS Curriculum v1.34 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf)

---

## Ejercicio 1 — Kubesec: escaneo de un Pod inseguro

1. Instalá `kubesec` vía Docker (no requiere binario local):

   ```bash
   docker pull kubesec/kubesec:v2
   ```

2. Creá un manifiesto deliberadamente inseguro, `insecure-pod.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: insecure-pod
   spec:
     containers:
     - name: app
       image: nginx:1.25
       securityContext:
         privileged: true
       volumeMounts:
       - name: host-root
         mountPath: /host
     volumes:
     - name: host-root
       hostPath:
         path: /
   ```

3. Corré el scan:

   ```bash
   docker run -i kubesec/kubesec:v2 scan /dev/stdin < insecure-pod.yaml
   ```

4. Leé la salida JSON: prestá atención a los campos `score`, `scoring.critical`, `scoring.advise` y `scoring.passed`.

**Preguntas de verificación:**
- ¿Qué indica que el `score` total sea negativo?
- En la salida, ¿qué dos hallazgos aparecen bajo `critical` para este Pod y por qué?

---

## Ejercicio 2 — Remediar según las recomendaciones de Kubesec

1. Reescribí el manifiesto anterior aplicando hardening: sacá `privileged` y el `hostPath`, y agregá un `securityContext` completo más `resources`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: hardened-pod
   spec:
     containers:
     - name: app
       image: nginx:1.25
       securityContext:
         runAsNonRoot: true
         runAsUser: 1000
         readOnlyRootFilesystem: true
         allowPrivilegeEscalation: false
         capabilities:
           drop:
           - ALL
       resources:
         limits:
           cpu: "200m"
           memory: "128Mi"
         requests:
           cpu: "100m"
           memory: "64Mi"
   ```

2. Volvé a escanear:

   ```bash
   docker run -i kubesec/kubesec:v2 scan /dev/stdin < hardened-pod.yaml
   ```

3. Compará el `score` con el del Ejercicio 1 y revisá qué ítems de `scoring.advise` desaparecieron.

**Preguntas de verificación:**
- ¿Por qué `capabilities.drop: [ALL]` suma puntos aunque el contenedor siga corriendo sin `capabilities.add`?
- Si el `score` sigue siendo bajo pese al hardening, ¿qué tipo de recomendaciones esperarías ver todavía en `advise` (a diferencia de `critical`)?

---

## Ejercicio 3 — Kubesec como servicio HTTP para CI

1. Levantá kubesec en modo servidor:

   ```bash
   docker run -d -p 8080:8080 kubesec/kubesec:v2 http 8080
   ```

2. Enviá el manifiesto vía HTTP en lugar de invocar el binario:

   ```bash
   curl -sS -X POST --data-binary @insecure-pod.yaml http://localhost:8080/scan
   ```

3. Compará la respuesta con la del Ejercicio 1 (debería ser equivalente).

**Preguntas de verificación:**
- ¿Qué ventaja tiene correr kubesec como servicio HTTP persistente frente a invocar el CLI en cada job de un pipeline?
- ¿Qué información necesitarías capturar del response (además del `score`) para bloquear automáticamente un merge en CI?

---

## Ejercicio 4 — KubeLinter: instalación y primer lint

1. Instalá `kube-linter` (vía `go install` o descargando el binario de releases):

   ```bash
   go install golang.stackrox.io/kube-linter/cmd/kube-linter@latest
   ```

2. Corré el lint sobre el Pod inseguro del Ejercicio 1:

   ```bash
   kube-linter lint insecure-pod.yaml
   ```

3. Leé la salida: cada finding muestra el nombre del check (ej. `privileged-container`), el objeto afectado y una línea de remediación sugerida.

**Preguntas de verificación:**
- A diferencia de Kubesec (que da un score numérico), ¿qué tipo de resultado produce KubeLinter por cada check?
- ¿Qué código de salida (`$?`) esperás después de un `kube-linter lint` que encontró findings?

---

## Ejercicio 5 — Lint de un directorio completo y catálogo de checks

1. Creá un segundo manifiesto, `risky-deploy.yaml`, en el mismo directorio que `insecure-pod.yaml`:

   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: risky-deploy
   spec:
     replicas: 1
     selector:
       matchLabels:
         app: risky
     template:
       metadata:
         labels:
           app: risky
       spec:
         hostPID: true
         containers:
         - name: app
           image: myapp:latest
           env:
           - name: DB_PASSWORD
             value: "supersecret"
   ```

2. Lintá el directorio completo:

   ```bash
   kube-linter lint .
   ```

3. Listá todos los checks builtin disponibles para ver el alcance total de la herramienta:

   ```bash
   kube-linter checks list
   ```

**Preguntas de verificación:**
- ¿Qué check esperás que dispare `hostPID: true` y por qué es riesgoso a nivel de aislación del namespace de procesos?
- ¿Qué check esperás que dispare tener `DB_PASSWORD` como valor plano en `env` en lugar de un `Secret`?
- Nombrá un check que también debería dispararse por usar la tag `latest` en `image`.

---

## Ejercicio 6 — Configuración personalizada con `.kube-linter.yaml`

1. Creá un archivo de configuración que excluya un check puntual y ajuste qué categorías se evalúan:

   ```yaml
   checks:
     doNotAutoAddDefaults: false
     exclude:
     - "unset-cpu-requirements"
     include:
     - "privileged-container"
     - "run-as-non-root"
   ```

2. Corré el lint usando esa config explícita:

   ```bash
   kube-linter lint --config .kube-linter.yaml .
   ```

3. Confirmá que el check excluido ya no aparece en la salida, aunque el manifiesto siga sin `resources.requests.cpu`.

**Preguntas de verificación:**
- ¿En qué escenario real tendría sentido excluir un check en vez de corregir el workload (pensá en falsos positivos o excepciones documentadas)?
- ¿Qué riesgo organizacional implica que cualquier equipo pueda editar libremente `.kube-linter.yaml` para silenciar checks?

---

## Ejercicio 7 — Gate de CI/CD basado en exit code

1. Corré el lint sobre el manifiesto hardened y revisá el exit code:

   ```bash
   kube-linter lint hardened-pod.yaml
   echo "exit code: $?"
   ```

2. Corré el lint sobre el manifiesto inseguro y comparalo:

   ```bash
   kube-linter lint insecure-pod.yaml
   echo "exit code: $?"
   ```

3. Esbozá un step de pipeline (ej. GitHub Actions) que use ese exit code como gate antes del `kubectl apply`:

   ```yaml
   - name: Static analysis (KubeLinter)
     run: kube-linter lint ./manifests
   - name: Deploy
     run: kubectl apply -f ./manifests
   ```

   Dado que un step con exit code distinto de `0` corta el job por default, el step `Deploy` nunca se ejecuta si el lint falla.

**Preguntas de verificación:**
- ¿Por qué el exit code (y no solo el texto del reporte) es el mecanismo que realmente bloquea un merge o un deploy en CI?
- Kubesec y KubeLinter corren antes del `kubectl apply`. ¿Qué tipo de control del cluster (mencionado en otros temas del dominio "Minimize Microservice Vulnerabilities") actúa como red de seguridad si igual llega un manifiesto inseguro al API server?

---

<details>
<summary><strong>Ver respuestas</strong></summary>

**Ejercicio 1**
- Un `score` negativo significa que las reglas `critical` (peso muy alto, ej. `privileged: true`, `hostNetwork: true`) pesaron más que cualquier punto positivo sumado por buenas prácticas presentes; kubesec usa `critical` para condiciones que por sí solas deberían bloquear el objeto.
- Los dos hallazgos críticos son: (1) `securityContext.privileged == true`, porque le da al contenedor acceso equivalente a root sobre el host (namespaces y capabilities sin restricción); y (2) el volumen `hostPath` montando `/` del nodo, que permite leer/escribir sobre todo el filesystem del host desde el contenedor, habilitando escape/persistencia trivial.

**Ejercicio 2**
- `capabilities.drop: [ALL]` suma puntos porque reduce la superficie de ataque del contenedor a la mínima expresión (sin `CAP_NET_RAW`, `CAP_SYS_ADMIN`, etc.), independientemente de si luego se agrega alguna capability puntual con `add`; kubesec valora el principio de least privilege explícito, no solo el resultado neto.
- Aun con hardening, `advise` seguiría sugiriendo cosas como definir `livenessProbe`/`readinessProbe`, fijar `imagePullPolicy: Always` (o pinnear el digest de la imagen), o evitar `:latest` — son buenas prácticas que kubesec valora pero no considera bloqueantes como `critical`.

**Ejercicio 3**
- Correr kubesec como servicio HTTP evita el overhead de levantar un container nuevo por cada invocación del pipeline (pull de imagen, arranque), permite escanear muchos manifiestos en paralelo contra la misma instancia, y facilita integrarlo como un microservicio interno consumido por varios pipelines o por un admission webhook.
- Para bloquear un merge automáticamente conviene capturar el `score` total y el array `scoring.critical` completo (no solo si está vacío o no), para poder loguear en el pipeline exactamente qué regla crítica falló y devolver un exit code distinto de 0 en el script que llama a la API.

**Ejercicio 4**
- KubeLinter produce un resultado tipo pass/fail por check (un finding por objeto+check que no cumple), no un puntaje agregado; cada finding trae el nombre del check y una remediación textual, pero no hay un "score" único del objeto.
- El exit code esperado es distinto de `0` (típicamente `1`) cuando hay findings, precisamente para poder usarlo como gate en CI.

**Ejercicio 5**
- `host-namespaces` (o el check específico de `hostPID`) se dispara porque compartir el namespace de PID del host permite al contenedor ver y potencialmente interactuar (señales, `/proc`) con todos los procesos del nodo, rompiendo el aislamiento entre workloads.
- `env-var-secret` (o equivalente) se dispara porque un valor sensible en `env.value` queda en texto plano, visible vía `kubectl describe`/`get -o yaml` y en el historial del manifiesto, en lugar de referenciarse desde un `Secret` con `valueFrom.secretKeyRef`.
- `latest-tag` es el check esperado: usar `:latest` impide reproducibilidad del build y dificulta rastrear qué versión exacta corre en producción, además de facilitar que una imagen mute sin control de versión explícito.

**Ejercicio 6**
- Tiene sentido excluir un check cuando la regla genera falsos positivos para un caso legítimo y documentado (ej. un DaemonSet de logging que necesita `hostPath` de forma justificada y ya fue revisado), siempre que la excepción quede registrada y no se use como atajo genérico.
- El riesgo es que, sin control de quién puede modificar `.kube-linter.yaml` (ej. sin revisión obligatoria vía code review de esa configuración), cualquier equipo puede silenciar checks de seguridad para evitar fricción, vaciando de sentido el gate de static analysis.

**Ejercicio 7**
- El exit code es lo único que el motor de CI evalúa mecánicamente para decidir si continúa o corta el pipeline; el texto del reporte es para que lo lea un humano, pero no tiene ningún efecto sobre el control de flujo del job si el exit code es `0`.
- La red de seguridad son los **admission controllers** (ValidatingAdmissionPolicy, Pod Security Admission, u OPA/Gatekeeper con sus políticas), que evalúan el objeto en el momento real del `kubectl apply` contra el API server — cubriendo el caso de que alguien aplique un manifiesto sin pasar por el pipeline de CI.

</details>