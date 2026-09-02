# CKS 4.4 — Ejercicios guiados: análisis estático de cargas de trabajo de usuario e imágenes de contenedor

> **Dominio:** Supply Chain Security (peso 5) — *Realizar análisis estático de cargas de trabajo de usuario e imágenes de contenedor (p. ej. Kubesec, KubeLinter)*
> **Versión del examen:** CKS 1.34
> **Formato:** pasos numerados que ejecutás, seguidos de preguntas de verificación. Todas las respuestas están en la sección plegable del final.

---

## Qué significa "análisis estático" acá, con precisión

Análisis estático en este dominio significa **derivar conclusiones de seguridad a partir de un manifiesto o de los metadatos de una imagen sin ejecutarlos**. Es barato, determinista y corre antes de que el API server vea el objeto — que es exactamente su valor y exactamente su límite:

| Capa | Clase de herramienta | Ve | No puede ver |
|---|---|---|---|
| Manifiesto fuente / chart de Helm | Kubesec, KubeLinter, `trivy config`, Checkov | La intención del autor, el YAML tal como está escrito | Defaulting del API server, webhooks de mutación, drift en vivo |
| Config de la imagen + capas | `skopeo inspect --config`, `crane config`, `docker history`, `trivy image --scanners secret` | `USER`, `ENV`, `ENTRYPOINT`, comandos de capa, secretos horneados | Comportamiento en runtime, syscalls |
| Admisión | PSA, Kyverno/Gatekeeper, kubesec-webhook | El objeto *efectivo* después del defaulting y la mutación | Mutación post-admisión por controladores |
| Runtime | Falco, eBPF, audit log | Syscalls y árboles de procesos reales | La intención |

El análisis estático es la **primera** compuerta, no la única. El Ejercicio 8 hace concreta la brecha entre "lo que decía el YAML" y "lo que el clúster corre".

> ⚠️ **Disciplina de versiones.** Los valores de puntos, los nombres de checks y los flags de abajo reflejan **kubesec v2.14.x** y **KubeLinter v0.7.x**. Ambos proyectos cambian reglas entre releases. Nunca memorices un número — leé los campos `scoring[].points` y `check:` en *tu propia* salida. En el examen, el primer comando que corrés contra una herramienta desconocida es `<tool> --help`.

---

## Ejercicio 0 — Entorno de laboratorio y espacio de trabajo

**Objetivo:** instalar ambos escáneres, verificar versiones y armar un espacio de trabajo que vas a reutilizar en todos los ejercicios.

1. Creá el espacio de trabajo:

```bash
mkdir -p ~/cks-4.4/{manifests,reports,chart}
cd ~/cks-4.4
```

2. Instalá Kubesec (binario estático, sin demonio, sin necesidad de acceso al clúster):

```bash
KUBESEC_VER=v2.14.2
curl -sSL "https://github.com/controlplaneio/kubesec/releases/download/${KUBESEC_VER}/kubesec_linux_amd64.tar.gz" \
  | tar -xz -C /tmp kubesec
sudo install -m 0755 /tmp/kubesec /usr/local/bin/kubesec
kubesec version
```

Esperado:

```
2.14.2
```

3. Instalá KubeLinter:

```bash
curl -sSLO https://github.com/stackrox/kube-linter/releases/latest/download/kube-linter-linux.tar.gz
tar -xzf kube-linter-linux.tar.gz kube-linter
sudo install -m 0755 kube-linter /usr/local/bin/kube-linter
rm -f kube-linter-linux.tar.gz kube-linter
kube-linter version
```

Esperado (la versión va a diferir):

```
0.7.2
```

4. Si no podés instalar binarios (nodo restringido, entorno air-gapped tipo examen), ambas herramientas se distribuyen como contenedores:

```bash
docker run --rm -i kubesec/kubesec:v2 scan /dev/stdin < manifests/01-payments-api.yaml
docker run --rm -v "$PWD":/dir:ro stackrox/kube-linter:latest lint /dir/manifests
```

5. Instalá `jq` — todo flujo de trabajo legible por máquina en este tema depende de él:

```bash
sudo apt-get install -y jq 2>/dev/null || sudo dnf install -y jq
jq --version
```

6. Leé ambas pantallas de ayuda **ahora**, antes de necesitarlas bajo presión de tiempo:

```bash
kubesec scan --help
kube-linter lint --help
kube-linter checks list --help
```

**Preguntas de verificación**

- **Q0.1** — Ninguna de las dos herramientas pidió un kubeconfig, un clúster o credenciales. ¿Qué te dice eso sobre *en qué momento* del pipeline de entrega están pensadas para correr, y qué clase de mala configuración nunca van a poder detectar por eso?
- **Q0.2** — Corriste el kubesec containerizado con `scan /dev/stdin`. ¿Por qué funciona ese argumento, y qué se rompería si en cambio corrieras `docker run --rm kubesec/kubesec:v2 scan manifests/01-payments-api.yaml`?
- **Q0.3** — En el examen CKS no podés navegar sitios arbitrarios. Si te dan `kube-linter` y te dicen "habilitá solo los checks que marcan contenedores privilegiados", ¿qué único comando te da el nombre autoritativo del check sin salir de la terminal?

---

## Ejercicio 1 — Un manifiesto deliberadamente hostil: tu primer escaneo con Kubesec

**Objetivo:** aprender a leer la salida JSON de Kubesec como el *resultado de un motor de reglas*, no como una nota.

1. Escribí la carga de trabajo bajo prueba. Este es un manifiesto realista de tipo "funciona en mi laptop" — cada uno de sus pecados aparece en clústeres reales:

```bash
cat > manifests/01-payments-api.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: payments-api
  namespace: default
spec:
  hostNetwork: true
  hostPID: true
  containers:
    - name: api
      image: registry.example.com/payments-api:latest
      securityContext:
        privileged: true
        capabilities:
          add: ["SYS_ADMIN", "NET_ADMIN"]
      volumeMounts:
        - name: docker-sock
          mountPath: /var/run/docker.sock
  volumes:
    - name: docker-sock
      hostPath:
        path: /var/run/docker.sock
EOF
```

2. Escaneálo:

```bash
kubesec scan manifests/01-payments-api.yaml
```

Salida esperada (abreviada; tus valores de puntos pueden diferir según la versión):

```json
[
  {
    "object": "Pod/payments-api.default",
    "valid": true,
    "fileName": "manifests/01-payments-api.yaml",
    "message": "Failed with a score of -88 points",
    "score": -88,
    "scoring": {
      "critical": [
        {
          "id": "CapSysAdmin",
          "selector": "containers[] .securityContext .capabilities .add == SYS_ADMIN",
          "reason": "CAP_SYS_ADMIN is the most privileged capability and should always be avoided",
          "points": -30
        },
        {
          "id": "Privileged",
          "selector": "containers[] .securityContext .privileged == true",
          "reason": "Privileged containers can allow almost completely unrestricted host access",
          "points": -30
        },
        {
          "id": "VolumeMountDockerSock",
          "selector": "volumes[] .hostPath .path == /var/run/docker.sock",
          "reason": "Mounting the docker.socket leaks information about other containers and can allow container breakout",
          "points": -9
        },
        {
          "id": "HostNetwork",
          "selector": ".spec .hostNetwork == true",
          "reason": "Sharing the host's network namespace permits processes in the pod to communicate with processes bound to the host's loopback adapter",
          "points": -9
        },
        {
          "id": "HostPID",
          "selector": ".spec .hostPID == true",
          "reason": "Sharing the host's PID namespace allows visibility of processes on the host, potentially leaking information such as environment variables and configuration",
          "points": -9
        },
        {
          "id": "CapabilitiesAdded",
          "selector": "containers[] .securityContext .capabilities .add",
          "reason": "Capabilities were added that increase the potential for container breakout",
          "points": -1
        }
      ],
      "advise": [
        { "id": "ApparmorAny", "selector": ".metadata .annotations .\"container.apparmor.security.beta.kubernetes.io/nginx\"", "reason": "Well defined AppArmor policies may provide greater protection from unknown threats.", "points": 3 },
        { "id": "AllowPrivilegeEscalation", "selector": "containers[] .securityContext .allowPrivilegeEscalation == false", "reason": "Ensure a non-root process can not gain more privileges", "points": 7 },
        { "id": "ServiceAccountName", "selector": ".spec .serviceAccountName", "reason": "Service accounts restrict Kubernetes API access and should be configured with least privilege", "points": 1 },
        { "id": "SeccompAny", "selector": ".metadata .annotations .\"container.seccomp.security.alpha.kubernetes.io/pod\"", "reason": "Seccomp profiles set minimum privilege and secure against unknown threats", "points": 1 },
        { "id": "RequestsCPU", "selector": "containers[] .resources .requests .cpu", "reason": "Enforcing CPU requests aids a fair balancing of resources across the cluster", "points": 1 },
        { "id": "LimitsMemory", "selector": "containers[] .resources .limits .memory", "reason": "Enforcing memory limits prevents DOS via resource exhaustion", "points": 1 }
      ],
      "passed": []
    }
  }
]
```

3. Extraé solo los números — esta es la forma que usa todo script de CI:

```bash
kubesec scan manifests/01-payments-api.yaml \
  | jq -r '.[] | "\(.object)\t\(.score)\t\(.message)"'
```

```
Pod/payments-api.default	-88	Failed with a score of -88 points
```

4. Listá solo los hallazgos críticos, ordenados por daño:

```bash
kubesec scan manifests/01-payments-api.yaml \
  | jq -r '.[].scoring.critical[] | "\(.points)\t\(.id)\t\(.reason)"' \
  | sort -n
```

5. Mirá el código de salida — el dato más importante para la automatización:

```bash
kubesec scan manifests/01-payments-api.yaml >/dev/null; echo "exit=$?"
```

```
exit=2
```

6. Ahora dale algo que *no* sea una carga de trabajo y observá el modo de falla:

```bash
cat > manifests/01b-service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: payments-api
spec:
  selector:
    app: payments-api
  ports:
    - port: 443
      targetPort: 8443
EOF

kubesec scan manifests/01b-service.yaml; echo "exit=$?"
```

Registrá exactamente qué imprime y qué código de salida devuelve. No lo asumas — este comportamiento es sensible a la versión y es precisamente lo que rompe en silencio un bucle ingenuo `for f in manifests/*.yaml`.

**Preguntas de verificación**

- **Q1.1** — Sumá a mano los valores de `points` del array `critical`. ¿Dan igual al `score` reportado? ¿Qué te dice eso sobre cómo se calcula el puntaje, y por qué el *número* es algo pobre para reportarle a un responsable de seguridad?
- **Q1.2** — `Privileged` cuesta −30 y `CapSysAdmin` cuesta −30, pero un contenedor privilegiado ya tiene todas las capabilities, incluida `CAP_SYS_ADMIN`. ¿Por qué Kubesec cobra por ambas, y qué revela ese doble conteo sobre el diseño del scoring basado en reglas?
- **Q1.3** — El array `advise` contiene `AllowPrivilegeEscalation` por **+7**, el mayor premio positivo del ruleset. Dado que este pod ya es `privileged: true`, ¿qué cambiaría realmente en runtime si pusieras `allowPrivilegeEscalation: false` y dejaras todo lo demás igual? ¿Cuál es la lección de seguridad sobre optimizar para el puntaje?
- **Q1.4** — El selector `ApparmorAny` en la salida referencia literalmente un contenedor llamado `nginx`, pero nuestro contenedor se llama `api`. Explicá qué está haciendo realmente ese selector y por qué el premio de AppArmor no se va a disparar para este pod.
- **Q1.5** — Código de salida 2, no 1. ¿Por qué importa esa distinción en un script de CI con `set -euo pipefail`, y cuál es la diferencia entre "el escaneo falló" y "el escáner falló"?
- **Q1.6** — Reportá qué hizo el paso 6 con el `Service`. ¿Cuál es la consecuencia operativa para un repo donde manifiestos, Services, ConfigMaps y CRDs conviven en el mismo directorio?

---

## Ejercicio 2 — Llevar el puntaje a positivo: endurecimiento iterativo

**Objetivo:** remediar la carga de trabajo control por control y ver cómo cada regla pasa de `advise`/`critical` a `passed`. Así se aprende el ruleset — no leyéndolo.

1. Escribí la versión endurecida. Cada campo acá mapea a una regla específica de Kubesec y al Pod Security Standard **Restricted**:

```bash
cat > manifests/02-payments-api-hardened.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: payments-api
  namespace: payments
  annotations:
    # Deprecated since Kubernetes 1.30 — kept here ONLY to demonstrate scanner lag.
    # See Q2.4 before you copy this into anything real.
    container.apparmor.security.beta.kubernetes.io/api: runtime/default
spec:
  serviceAccountName: payments-api
  automountServiceAccountToken: false
  hostNetwork: false
  hostPID: false
  hostIPC: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 20001
    runAsGroup: 20001
    fsGroup: 20001
    seccompProfile:
      type: RuntimeDefault
    appArmorProfile:
      type: RuntimeDefault
  containers:
    - name: api
      image: registry.example.com/payments-api@sha256:5f8f1a4e2c9b6d0a7e3c1b8f4d2a9c6e0b7d3f1a8c5e2b9d6f0a3c7e1b4d8f2a
      imagePullPolicy: IfNotPresent
      securityContext:
        privileged: false
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        runAsNonRoot: true
        runAsUser: 20001
        capabilities:
          drop: ["ALL"]
      resources:
        requests:
          cpu: "100m"
          memory: "128Mi"
        limits:
          cpu: "500m"
          memory: "512Mi"
      volumeMounts:
        - name: tmp
          mountPath: /tmp
        - name: cache
          mountPath: /var/cache/app
  volumes:
    - name: tmp
      emptyDir: {}
    - name: cache
      emptyDir: {}
EOF
```

2. Escaneálo:

```bash
kubesec scan manifests/02-payments-api-hardened.yaml | jq '.[] | {score, message}'
```

Esperado (aproximado — leé tu propia salida):

```json
{
  "score": 18,
  "message": "Passed with a score of 18 points"
}
```

3. Mirá exactamente qué reglas ganaste:

```bash
kubesec scan manifests/02-payments-api-hardened.yaml \
  | jq -r '.[].scoring.passed[] | "+\(.points)\t\(.id)"' | sort -rn
```

```
+7	AllowPrivilegeEscalation
+1	CapDropAll
+1	CapDropAny
+1	LimitsCPU
+1	LimitsMemory
+1	ReadOnlyRootFilesystem
+1	RequestsCPU
+1	RequestsMemory
+1	RunAsNonRoot
+1	RunAsUser10000
+1	SeccompAny
+1	ServiceAccountName
```

4. Diffeá los dos escaneos mecánicamente — este es el artefacto que adjuntás a un change request:

```bash
diff <(kubesec scan manifests/01-payments-api.yaml \
        | jq -r '.[].scoring | (.critical//[])[].id' | sort) \
     <(kubesec scan manifests/02-payments-api-hardened.yaml \
        | jq -r '.[].scoring | (.critical//[])[].id' | sort)
```

5. Ahora rompélo deliberadamente, un campo por vez, y volvé a escanear después de cada edición. Hacélo **cinco veces**, registrando el delta:

```bash
# a) remove capabilities.drop
# b) set readOnlyRootFilesystem: false
# c) set runAsUser: 999
# d) delete resources.limits
# e) add hostIPC: true at pod level
```

```bash
for variant in a b c d e; do
  echo -n "$variant: "
  kubesec scan "manifests/02-variant-${variant}.yaml" | jq -r '.[].score'
done
```

**Preguntas de verificación**

- **Q2.1** — En el paso 5c cambiaste `runAsUser` de `20001` a `999`. El pod sigue sin correr como root. ¿Por qué bajó igual el puntaje, y qué ataque del mundo real mitiga realmente la regla `RunAsUser10000` (`runAsUser > 10000`)?
- **Q2.2** — `CapDropAll` y `CapDropAny` son reglas separadas que valen +1 cada una, pero `drop: ["ALL"]` satisface ambas. Construí un bloque `capabilities` que satisfaga `CapDropAny` pero **no** `CapDropAll`, y explicá cuándo esa forma más débil es legítima en producción.
- **Q2.3** — El manifiesto pone `readOnlyRootFilesystem: true` y después monta dos volúmenes `emptyDir`. ¿Por qué esa combinación es casi siempre necesaria, y qué falla concreta en runtime ves si activás el flag sin agregar los montajes escribibles?
- **Q2.4** — El manifiesto lleva **tanto** `container.apparmor.security.beta.kubernetes.io/api` (anotación) **como** `securityContext.appArmorProfile` (campo). ¿Cuál honra Kubernetes 1.34, cuál busca la regla `ApparmorAny` de Kubesec, y cuál es la respuesta de ingeniería correcta cuando un escáner premia un campo deprecado?
- **Q2.5** — El pod endurecido saca 18. Un segundo manifiesto en el mismo repo saca 22 porque agrega una anotación de AppArmor y un PVC con `ReadWriteOnce`. ¿La carga de trabajo de 22 puntos es más segura? Justificá tu respuesta en términos de qué es y qué no es el puntaje.
- **Q2.6** — `automountServiceAccountToken: false` es discutiblemente la línea de mayor valor de este manifiesto, y sin embargo gana **cero** puntos de Kubesec. Explicá el riesgo que elimina, y enunciá el principio general que esto ilustra sobre los programas de seguridad guiados por puntaje.
- **Q2.7** — La referencia de imagen está fijada por digest (`@sha256:...`) en vez de por tag. Kubesec no tiene una regla para esto. ¿Qué ataque de cadena de suministro derrota el pin por digest, y cuál de las dos herramientas de este ejercicio *sí* marca `:latest`?

---

## Ejercicio 3 — Kubesec para máquinas: códigos de salida, plantillas y modo servidor

**Objetivo:** hacer a Kubesec usable dentro de una compuerta, un webhook o un plugin de editor.

1. Controlá el código de salida de falla explícitamente:

```bash
kubesec scan --exit-code 0 manifests/01-payments-api.yaml >/dev/null; echo "exit=$?"
kubesec scan --exit-code 7 manifests/01-payments-api.yaml >/dev/null; echo "exit=$?"
```

```
exit=0
exit=7
```

2. Generá un reporte legible por humanos con una plantilla Go en lugar de JSON:

```bash
cat > reports/kubesec.tmpl <<'EOF'
{{ range . }}{{ .Object }} => {{ .Score }}
{{ range .Scoring.Critical }}  [CRIT] {{ .Points }} {{ .ID }}
{{ end }}{{ range .Scoring.Advise }}  [ADV ] +{{ .Points }} {{ .ID }}
{{ end }}{{ end }}
EOF

kubesec scan --format template --template "$(cat reports/kubesec.tmpl)" \
  manifests/01-payments-api.yaml
```

3. Arrancá Kubesec en modo servidor HTTP — este es el mismo camino de código que usa el webhook de admisión:

```bash
kubesec http 8080 &
sleep 1
curl -sSX POST --data-binary @manifests/01-payments-api.yaml \
  http://localhost:8080/scan | jq '.[] | {score, message}'
```

```json
{
  "score": -88,
  "message": "Failed with a score of -88 points"
}
```

4. Compará con la API pública alojada, y después pensálo bien:

```bash
curl -sSX POST --data-binary @manifests/02-payments-api-hardened.yaml \
  https://v2.kubesec.io/scan | jq '.[].score'
```

5. Detené el servidor local:

```bash
kill %1
```

6. Armá una compuerta con umbral — Kubesec no tiene un flag de "puntaje mínimo" incorporado, así que lo imponés vos:

```bash
cat > kubesec-gate.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
MIN=${MIN:-5}
rc=0
shopt -s nullglob
for f in manifests/*.yaml; do
  out=$(kubesec scan --exit-code 0 "$f" 2>/dev/null) || { echo "SKIP  $f (not a workload)"; continue; }
  echo "$out" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1 || { echo "SKIP  $f"; continue; }
  while IFS=$'\t' read -r obj score; do
    if (( score < MIN )); then
      echo "FAIL  $obj  score=$score  (min=$MIN)  [$f]"
      rc=1
    else
      echo "PASS  $obj  score=$score  [$f]"
    fi
  done < <(echo "$out" | jq -r '.[] | "\(.object)\t\(.score)"')
done
exit $rc
EOF
chmod +x kubesec-gate.sh
MIN=10 ./kubesec-gate.sh; echo "gate exit=$?"
```

**Preguntas de verificación**

- **Q3.1** — Sacá `--exit-code 0` del script de la compuerta y volvé a correrlo. Predecí la salida antes de ejecutarlo, y después explicá exactamente qué opción del shell mató el bucle y por qué `|| true` solo sobre la llamada a `kubesec` seguiría sin alcanzar.
- **Q3.2** — En el paso 4 hiciste POST de un manifiesto a `v2.kubesec.io`, un servicio de terceros. Enumerá qué divulgaste. ¿En qué circunstancias es aceptable, y cuál es la remediación directa que preserva el flujo de trabajo?
- **Q3.3** — El modo servidor de Kubesec lo hace trivialmente desplegable como un `ValidatingAdmissionWebhook`. Nombrá dos propiedades de la validación basada en puntaje que la hacen *mala* candidata para una compuerta de admisión dura comparada con Pod Security Admission o una política de Kyverno/Gatekeeper.
- **Q3.4** — La compuerta usa `MIN=10` como umbral. Un desarrollador agrega `resources.requests.cpu`, `resources.requests.memory` y un `serviceAccountName` a un pod que sigue siendo `privileged: true`. ¿Puede pasar así una compuerta de umbral? Rediseñá la condición de aprobación de la compuerta en una sola oración para que no pueda.
- **Q3.5** — ¿Por qué el script prueba `jq -e 'type == "array" and length > 0'` antes de parsear? ¿Qué forma de entrada haría, si no, que el bucle `while read` procese silenciosamente nada mientras reporta éxito?

---

## Ejercicio 4 — KubeLinter: la segunda opinión

**Objetivo:** KubeLinter es un *motor de checks*, no un scorer. Aprendé la forma de su salida, su conjunto de checks por defecto, y dónde discrepa con Kubesec.

1. Lintéa el manifiesto hostil:

```bash
kube-linter lint manifests/01-payments-api.yaml
```

Esperado (abreviado):

```
KubeLinter v0.7.2

manifests/01-payments-api.yaml: (object: default/payments-api /v1, Kind=Pod) container "api" does not have a read-only root file system (check: no-read-only-root-fs, remediation: Set readOnlyRootFilesystem to true in your container's securityContext.)

manifests/01-payments-api.yaml: (object: default/payments-api /v1, Kind=Pod) container "api" is not set to runAsNonRoot (check: run-as-non-root, remediation: Set runAsUser to a non-zero number and runAsNonRoot to true in your pod or container securityContext. Refer to https://kubernetes.io/docs/tasks/configure-pod-container/security-context/ for details.)

manifests/01-payments-api.yaml: (object: default/payments-api /v1, Kind=Pod) container "api" does not have a CPU request (check: unset-cpu-requirements, remediation: Set CPU requests for your container.)

manifests/01-payments-api.yaml: (object: default/payments-api /v1, Kind=Pod) container "api" does not have a memory limit (check: unset-memory-requirements, remediation: Set memory limits for your container.)

manifests/01-payments-api.yaml: (object: default/payments-api /v1, Kind=Pod) container "api" is privileged (check: privileged-container, remediation: Do not run your container as privileged unless it is required.)

manifests/01-payments-api.yaml: (object: default/payments-api /v1, Kind=Pod) container "api" does not drop NET_RAW capability (check: drop-net-raw-capability, remediation: Add NET_RAW to the list of dropped capabilities in the container securityContext.)

manifests/01-payments-api.yaml: (object: default/payments-api /v1, Kind=Pod) container "api" does not specify a liveness probe (check: no-liveness-probe, remediation: Specify a liveness probe in your container.)

manifests/01-payments-api.yaml: (object: default/payments-api /v1, Kind=Pod) container "api" does not specify a readiness probe (check: no-readiness-probe, remediation: Specify a readiness probe in your container.)

Error: found 8 lint errors
```

2. Confirmá el código de salida:

```bash
kube-linter lint manifests/01-payments-api.yaml >/dev/null 2>&1; echo "exit=$?"
```

```
exit=1
```

3. Enumerá los checks que corrieron por defecto — no memorices, consultá:

```bash
kube-linter checks list --format json \
  | jq -r '.[] | select(.default == true) | .name' | sort | column -c 100
```

4. Contá cuántos checks existen en total contra cuántos están activos por defecto:

```bash
kube-linter checks list --format json | jq 'length'
kube-linter checks list --format json | jq '[.[] | select(.default)] | length'
```

5. Inspeccioná un check completo, incluyendo su template y parámetros:

```bash
kube-linter checks list --format json \
  | jq '.[] | select(.name == "privileged-container")'
```

6. Lintéa el manifiesto endurecido y notá qué *sigue* fallando:

```bash
kube-linter lint manifests/02-payments-api-hardened.yaml
```

7. Obtené salida legible por máquina para un pipeline:

```bash
kube-linter lint --format json manifests/ \
  | jq -r '.Reports[] | "\(.Check)\t\(.Object.K8sObject.Name)\t\(.Diagnostic.Message)"'
```

8. Producí SARIF para ingesta en GitHub code scanning / SonarQube:

```bash
kube-linter lint --format sarif manifests/ > reports/kube-linter.sarif
jq '.runs[0].results | length' reports/kube-linter.sarif
```

**Preguntas de verificación**

- **Q4.1** — KubeLinter reportó `no-liveness-probe` y `no-readiness-probe`; Kubesec no mencionó probes en absoluto. Kubesec reportó `hostPID` y el montaje de `docker.sock` como críticos; el conjunto por defecto de KubeLinter no marcó ninguno de los dos. ¿Qué te dice esa divergencia sobre correr un solo analizador estático, y cuál es la política correcta?
- **Q4.2** — `unset-cpu-requirements` y `no-liveness-probe` son checks de confiabilidad, no de seguridad. Argumentá *ambos* lados: ¿por qué un linter de seguridad los trae activos por defecto, y cuál es el costo de dejarlos activos en una compuerta de seguridad?
- **Q4.3** — `drop-net-raw-capability` se dispara incluso en contenedores que no son privilegiados. ¿Qué puede hacer un proceso con `CAP_NET_RAW` que justifique un check dedicado, y por qué eliminarla no alcanza por sí sola cuando el pod además tiene `hostNetwork: true`?
- **Q4.4** — En el paso 6, el manifiesto endurecido igual produjo errores de lint. Nombrá los dos checks que deben seguir disparándose dado el manifiesto del Ejercicio 2, y explicá por qué un pod endurecido en seguridad puede fallar legítimamente una corrida por defecto de KubeLinter.
- **Q4.5** — KubeLinter sale con `1`; Kubesec sale con `2`. Escribí la única línea de shell que trate el código no-cero de *cualquiera* de las dos herramientas como falla de compuerta y aun así distinga "hallazgos" de "la herramienta se cayó" (pista: pensá qué código de salida produce un binario faltante o un error de parseo).
- **Q4.6** — El identificador de objeto impreso es `default/payments-api /v1, Kind=Pod`. Si el mismo manifiesto omitiera `metadata.namespace`, ¿qué imprimiría KubeLinter, y por qué importa eso cuando diffeás reportes de lint entre entornos?

---

## Ejercicio 5 — Ajustar KubeLinter: archivo de configuración, checks personalizados, charts de Helm

**Objetivo:** convertir a KubeLinter de un ruidoso conjunto por defecto en un estándar organizacional aplicable.

1. Creá un archivo de configuración que parta de *todos* los checks incorporados y reste deliberadamente:

```bash
cat > .kube-linter.yaml <<'EOF'
checks:
  # Start from every built-in check, then remove what we consciously accept.
  addAllBuiltIn: true
  exclude:
    # Availability checks belong to the reliability gate, not the security gate.
    - "unset-cpu-requirements"
    - "no-anti-affinity"
    - "no-liveness-probe"
    - "no-readiness-probe"
    - "minimum-three-replicas"
  include:
    # Non-default checks we DO want, because they are supply-chain relevant.
    - "latest-tag"
    - "no-read-only-root-fs"
    - "privileged-ports"
    - "unsafe-sysctls"

customChecks:
  - name: require-owner-label
    template: "required-label"
    params:
      key: "owner"
    scope:
      objectKinds:
        - DeploymentLike
    description: "Every workload must declare an owning team so findings can be routed."
    remediation: "Add metadata.labels.owner=<team-slack-handle> to the workload."

  - name: forbid-default-serviceaccount
    template: "non-existent-service-account"
    scope:
      objectKinds:
        - DeploymentLike
    description: "Workloads must not silently fall back to the default ServiceAccount."
    remediation: "Create a dedicated ServiceAccount and set spec.serviceAccountName."
EOF
```

2. Descubrí a partir de qué templates podés construir checks personalizados, y qué parámetros acepta cada uno:

```bash
kube-linter templates list --format json \
  | jq -r '.[] | "\(.key)\t\(.description)"' | head -40
```

Mirá específicamente el esquema de parámetros de un template:

```bash
kube-linter templates list --format json \
  | jq '.[] | select(.key == "required-label")'
```

3. Corré con la configuración y observá la diferencia de volumen:

```bash
kube-linter lint --config .kube-linter.yaml manifests/ 2>&1 | tail -5
kube-linter lint manifests/ 2>&1 | tail -5
```

4. Armá un chart de Helm mínimo y linteálo **sin renderizarlo vos mismo**:

```bash
mkdir -p chart/templates
cat > chart/Chart.yaml <<'EOF'
apiVersion: v2
name: payments
version: 0.1.0
appVersion: "1.0.0"
EOF

cat > chart/values.yaml <<'EOF'
image:
  repository: registry.example.com/payments-api
  tag: latest
replicas: 1
EOF

cat > chart/templates/deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}-payments
spec:
  replicas: {{ .Values.replicas }}
  selector:
    matchLabels: { app: payments }
  template:
    metadata:
      labels: { app: payments }
    spec:
      containers:
        - name: api
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          securityContext:
            allowPrivilegeEscalation: true
EOF

kube-linter lint --config .kube-linter.yaml chart/
```

5. Ahora intentá darle el *mismo* chart a Kubesec:

```bash
kubesec scan chart/templates/deployment.yaml; echo "exit=$?"
```

Registrá la falla con precisión, y después hacelo de la forma que sí funciona:

```bash
helm template payments ./chart > /tmp/rendered.yaml
kubesec scan /tmp/rendered.yaml | jq -r '.[] | "\(.object)\t\(.score)"'
```

6. Agregá un hook de pre-commit para que nadie tenga que acordarse de correr esto:

```bash
cat > .pre-commit-config.yaml <<'EOF'
repos:
  - repo: local
    hooks:
      - id: kube-linter
        name: kube-linter
        entry: kube-linter lint --config .kube-linter.yaml
        language: system
        files: ^(manifests|chart)/.*\.(ya?ml)$
        pass_filenames: false
EOF
```

**Preguntas de verificación**

- **Q5.1** — La configuración usa `addAllBuiltIn: true` más una lista explícita de `exclude`, en vez de `include`-ir los checks que el equipo quiere. Argumentá por qué la forma sustractiva es el default más seguro para una línea base de seguridad, y nombrá la única situación en la que la forma aditiva es correcta.
- **Q5.2** — En el paso 5, Kubesec falló con `chart/templates/deployment.yaml` mientras KubeLinter manejó el directorio del chart. Explicá la razón arquitectónica de esa diferencia, y enunciá la regla general de dónde pertenece cada herramienta en un pipeline de Helm.
- **Q5.3** — `helm template` renderiza con los valores por defecto de `values.yaml`. Tu despliegue de producción usa `values-prod.yaml`, que pone `securityContext.privileged: true` para un sidecar de depuración. ¿Qué reporta tu compuerta, y cuál es el arreglo?
- **Q5.4** — El check personalizado `require-owner-label` usa `scope.objectKinds: [DeploymentLike]`. ¿A qué se expande `DeploymentLike`, y qué pasa con un `Pod` pelado o un `CronJob` bajo ese alcance?
- **Q5.5** — Habilitaste `latest-tag`. Un desarrollador objeta: "la imagen también está fijada por digest en el overlay de CD, así que el tag es irrelevante". ¿Sigue valiendo la pena imponer el check sobre el manifiesto fuente? Explicá en términos de qué controla un atacante.
- **Q5.6** — El hook de pre-commit pone `pass_filenames: false`. ¿Qué saldría mal con `pass_filenames: true`, dado cómo KubeLinter resuelve checks entre objetos como `dangling-service` y `non-existent-service-account`?

---

## Ejercicio 6 — Análisis estático de la imagen de contenedor en sí

**Objetivo:** el syllabus dice *"cargas de trabajo **e imágenes de contenedor**"*. El linteo de manifiestos no dice nada sobre qué hay adentro de la imagen. Aprendé a interrogar la configuración y la historia de una imagen sin descargarla ni ejecutarla.

1. Leé el objeto de configuración de una imagen directamente desde el registry — sin `docker pull`, sin demonio:

```bash
skopeo inspect --config docker://docker.io/library/nginx:1.27 \
  | jq '{user: .config.User, entrypoint: .config.Entrypoint, cmd: .config.Cmd, env: .config.Env, exposed: .config.ExposedPorts}'
```

Esperado (abreviado):

```json
{
  "user": "",
  "entrypoint": ["/docker-entrypoint.sh"],
  "cmd": ["nginx", "-g", "daemon off;"],
  "env": ["PATH=/usr/local/sbin:...", "NGINX_VERSION=1.27.3", "NJS_VERSION=0.8.7"],
  "exposed": { "80/tcp": {} }
}
```

2. Lo mismo con `crane` (de `go-containerregistry`), que muchas imágenes de CI ya traen:

```bash
crane config docker.io/library/nginx:1.27 | jq -r '.config.User // "(empty => root)"'
```

3. Leé la historia de build estáticamente — acá es donde viven los secretos filtrados:

```bash
crane config docker.io/library/nginx:1.27 \
  | jq -r '.history[] | .created_by' | head -20
```

4. Construí una imagen deliberadamente mala localmente y auditála de la misma forma:

```bash
cat > Dockerfile <<'EOF'
FROM ubuntu:24.04
ARG NPM_TOKEN
ENV DB_PASSWORD=s3cr3t-do-not-do-this
RUN apt-get update && apt-get install -y curl sudo
COPY app /opt/app
EXPOSE 22
CMD ["/opt/app/server"]
EOF

mkdir -p app && echo '#!/bin/sh' > app/server && chmod +x app/server
docker build -t bad-app:0.1 .
```

5. Analizá el Dockerfile estáticamente — sin build, sin ejecución:

```bash
trivy config Dockerfile
```

Esperado (abreviado):

```
Dockerfile (dockerfile)
=======================
Tests: 27 (SUCCESSES: 24, FAILURES: 3)
Failures: 3 (UNKNOWN: 0, LOW: 0, MEDIUM: 1, HIGH: 2, CRITICAL: 0)

HIGH: Specify at least 1 USER command in Dockerfile with non-root user as argument
──────────────────────────────────────────
Running containers with 'root' user can lead to a container escape situation...
See https://avd.aquasec.com/misconfig/ds002
──────────────────────────────────────────

HIGH: Sensitive data should not be used in the ARG or ENV commands
──────────────────────────────────────────
See https://avd.aquasec.com/misconfig/ds031
──────────────────────────────────────────

MEDIUM: Add HEALTHCHECK instruction in your Dockerfile
──────────────────────────────────────────
See https://avd.aquasec.com/misconfig/ds026
──────────────────────────────────────────
```

6. Escaneá la imagen construida en busca de secretos horneados en las capas — sigue siendo estático, sin ejecución:

```bash
trivy image --scanners secret --severity HIGH,CRITICAL bad-app:0.1
docker image inspect bad-app:0.1 --format '{{.Config.User}} | {{join .Config.Env ","}}'
```

7. Conectá el análisis de imagen de vuelta con el manifiesto. Desplegá una imagen cuyo `USER` es root bajo un pod con `runAsNonRoot: true`:

```bash
kubectl run root-image --image=bad-app:0.1 \
  --overrides='{"spec":{"containers":[{"name":"root-image","image":"bad-app:0.1","securityContext":{"runAsNonRoot":true}}]}}'
kubectl get pod root-image
kubectl describe pod root-image | grep -A3 -i 'Warning\|Error'
```

Esperado:

```
NAME         READY   STATUS                       RESTARTS   AGE
root-image   0/1     CreateContainerConfigError   0          6s
```

```
  Warning  Failed     3s (x3 over 12s)  kubelet  Error: container has runAsNonRoot and image will run as root
```

8. Limpieza:

```bash
kubectl delete pod root-image --ignore-not-found
```

**Preguntas de verificación**

- **Q6.1** — `skopeo inspect --config` devolvió `"user": ""`. ¿Qué significa un `Config.User` vacío, y por qué ese campo es lo más útil que podés extraer de la configuración de una imagen durante una revisión de cadena de suministro?
- **Q6.2** — En el paso 7 el pod falló con `CreateContainerConfigError`, no con `CrashLoopBackOff`. ¿En qué etapa ocurrió la verificación, qué componente la impuso, y por qué `runAsNonRoot: true` *solo* es insuficiente si no podés además fijar `runAsUser`?
- **Q6.3** — `ENV DB_PASSWORD=s3cr3t` queda visible en la configuración de la imagen para siempre. Supongamos que el desarrollador en cambio escribe `RUN echo $NPM_TOKEN > /tmp/.npmrc && npm ci && rm /tmp/.npmrc`. ¿Es recuperable el token desde la imagen publicada? Explicá en términos de capas, y nombrá la funcionalidad de build que lo resuelve correctamente.
- **Q6.4** — `trivy config Dockerfile` y `kube-linter lint manifests/` ambos reportan "corre como root", desde entradas completamente distintas. ¿Cuál puede equivocarse, y en qué dirección? Dá un par manifiesto+imagen concreto donde el manifiesto se ve limpio y la carga de trabajo igual corre como UID 0.
- **Q6.5** — `EXPOSE 22` no disparó nada en `trivy config`, pero KubeLinter trae un check `ssh-port` para manifiestos. ¿Por qué `EXPOSE` en un Dockerfile es una señal débil, y qué hace realmente en runtime dentro de Kubernetes?
- **Q6.6** — Tenés 400 imágenes en tu registry. Escribí (en palabras) la pasada de análisis estático que encuentra toda imagen que corre como root, usando solo `crane`/`skopeo` + `jq`, y explicá por qué eso es mejor que esperar un rechazo de admisión por `runAsNonRoot` en producción.

---

## Ejercicio 7 — Una compuerta de CI que realmente bloquea

**Objetivo:** combinar ambos escáneres en una única compuerta determinista con un contrato de falla honesto.

1. Escribí la compuerta:

```bash
cat > ci-static-analysis.sh <<'EOF'
#!/usr/bin/env bash
# Static analysis gate for Kubernetes workloads.
# Exit 0 = clean, 1 = policy findings, 2 = tooling/usage error.
set -uo pipefail

MANIFEST_DIR=${MANIFEST_DIR:-manifests}
MIN_SCORE=${MIN_SCORE:-5}
findings=0

command -v kubesec    >/dev/null || { echo "tooling: kubesec not found";    exit 2; }
command -v kube-linter>/dev/null || { echo "tooling: kube-linter not found"; exit 2; }
command -v jq         >/dev/null || { echo "tooling: jq not found";          exit 2; }

echo "== KubeLinter =="
kube-linter lint --config .kube-linter.yaml --format json "$MANIFEST_DIR" > /tmp/kl.json 2>/tmp/kl.err
kl_rc=$?
if (( kl_rc > 1 )); then
  echo "tooling: kube-linter failed (rc=$kl_rc)"; cat /tmp/kl.err; exit 2
fi
kl_count=$(jq '(.Reports // []) | length' /tmp/kl.json)
jq -r '(.Reports // [])[] | "  [\(.Check)] \(.Object.K8sObject.Namespace)/\(.Object.K8sObject.Name): \(.Diagnostic.Message)"' /tmp/kl.json
(( kl_count > 0 )) && findings=1
echo "  -> $kl_count check violation(s)"

echo "== Kubesec =="
shopt -s nullglob
for f in "$MANIFEST_DIR"/*.y*ml; do
  out=$(kubesec scan --exit-code 0 "$f" 2>/tmp/ks.err)
  if ! jq -e 'type=="array" and length>0' <<<"$out" >/dev/null 2>&1; then
    echo "  SKIP $f (no scannable workload)"
    continue
  fi
  while IFS=$'\t' read -r obj score crit; do
    if (( crit > 0 )); then
      echo "  FAIL $obj score=$score critical=$crit  <- hard block"
      findings=1
    elif (( score < MIN_SCORE )); then
      echo "  FAIL $obj score=$score (< $MIN_SCORE)"
      findings=1
    else
      echo "  PASS $obj score=$score"
    fi
  done < <(jq -r '.[] | "\(.object)\t\(.score)\t\((.scoring.critical // []) | length)"' <<<"$out")
done

exit $findings
EOF
chmod +x ci-static-analysis.sh
```

2. Corréla contra el directorio malo, y después contra uno limpio:

```bash
MANIFEST_DIR=manifests ./ci-static-analysis.sh; echo "gate=$?"
mkdir -p clean && cp manifests/02-payments-api-hardened.yaml clean/
MANIFEST_DIR=clean ./ci-static-analysis.sh; echo "gate=$?"
```

3. Comprobá que el camino de error de herramientas es distinguible:

```bash
PATH=/nonexistent ./ci-static-analysis.sh; echo "gate=$?"
```

```
tooling: kubesec not found
gate=2
```

4. Agregá un mecanismo de exención — porque una compuerta sin proceso de exención termina desactivada:

```bash
cat >> .kube-linter.yaml <<'EOF'
EOF
# In-manifest waiver, scoped to one object and one check:
#   metadata:
#     annotations:
#       ignore-check.kube-linter.io/privileged-container: "CSI node driver requires privileged mode; approved SEC-2291, expires 2026-12-01"
```

Aplicálo a una carga de trabajo genuinamente privilegiada y confirmá que el hallazgo desaparece:

```bash
kubectl create deploy csi-node --image=registry.example.com/csi:1.2 --dry-run=client -o yaml > manifests/03-csi.yaml
# hand-edit: add privileged: true, then the ignore-check annotation on the pod template metadata
kube-linter lint --config .kube-linter.yaml manifests/03-csi.yaml
```

**Preguntas de verificación**

- **Q7.1** — La compuerta trata "cualquier hallazgo `critical` de Kubesec" como bloqueo duro sin importar el puntaje total. ¿Por qué esa regla es estrictamente mejor que un umbral de puntaje solo? Dá el manifiesto específico que derrota una compuerta de puro umbral.
- **Q7.2** — A los códigos de salida 0/1/2 se les dan significados distintos. ¿Por qué "error de herramienta" tiene que ser distinguible de "violación de política" en un sistema de CI, y cuál es el modo de falla peligroso si ambos devuelven 1?
- **Q7.3** — La exención es una anotación dentro del propio manifiesto, lo que significa que quien introduce el riesgo también otorga la excepción. Describí dos controles que hacen esto aceptable, y uno que no (autoaprobación).
- **Q7.4** — `ignore-check.kube-linter.io/<check>` se aplica exactamente dónde, para un Deployment: ¿en `metadata.annotations` o en `spec.template.metadata.annotations`? Explicá por qué la respuesta depende del alcance del check.
- **Q7.5** — Kubesec **no** tiene mecanismo de exención alguno. Dado eso, ¿cómo corrés Kubesec en un repo que legítimamente contiene un DaemonSet CSI privilegiado, sin desactivar la herramienta ni aceptar un build permanentemente en rojo?
- **Q7.6** — La compuerta corre sobre `manifests/`, pero tu repo GitOps es la fuente de verdad del despliegue y Argo CD aplica overlays de Kustomize. ¿Dónde tiene que correr realmente la compuerta para ser significativa, y cómo se llama la falla que previene?

---

## Ejercicio 8 — Auditar un clúster vivo con las mismas herramientas

**Objetivo:** aplicar análisis estático a lo que el clúster está *realmente* corriendo, y medir la brecha contra los manifiestos fuente.

1. Desplegá el pod hostil en un namespace descartable (usá un clúster desechable — kind/minikube):

```bash
kubectl create ns audit-lab
sed 's/namespace: default/namespace: audit-lab/' manifests/01-payments-api.yaml \
  | kubectl apply -f - 2>&1 | tail -2
```

Si Pod Security Admission lo bloquea, anotá el mensaje y después etiquetá temporalmente el namespace:

```bash
kubectl label ns audit-lab pod-security.kubernetes.io/enforce=privileged --overwrite
kubectl apply -n audit-lab -f manifests/01-payments-api.yaml
```

2. Exportá cada carga de trabajo del clúster a disco, un archivo por objeto:

```bash
mkdir -p live
for kind in deployment daemonset statefulset cronjob job pod; do
  kubectl get "$kind" -A -o json 2>/dev/null \
    | jq -c '.items[]?' \
    | while read -r obj; do
        ns=$(jq -r '.metadata.namespace' <<<"$obj")
        name=$(jq -r '.metadata.name' <<<"$obj")
        jq 'del(.status, .metadata.managedFields, .metadata.uid, .metadata.resourceVersion, .metadata.generation, .metadata.creationTimestamp)' \
          <<<"$obj" > "live/${kind}_${ns}_${name}.json"
      done
done
ls live | wc -l
```

3. Lintéa toda la exportación de una sola vez:

```bash
kube-linter lint --config .kube-linter.yaml live/ --format json \
  | jq -r '.Reports[] | .Check' | sort | uniq -c | sort -rn | head -15
```

Forma esperada:

```
     42 no-read-only-root-fs
     38 run-as-non-root
     31 unset-memory-requirements
     12 drop-net-raw-capability
      3 privileged-container
      1 host-network
```

4. Puntuá cada carga de trabajo con Kubesec y rankeá a los peores infractores:

```bash
for f in live/*.json; do
  kubesec scan "$f" --exit-code 0 2>/dev/null \
    | jq -r --arg f "$f" '.[]? | "\(.score)\t\(.object)\t\($f)"'
done | sort -n | head -10
```

5. **El experimento crítico.** Escaneá el manifiesto *fuente* y el objeto *vivo* del mismo pod y diffeá los puntajes:

```bash
kubesec scan manifests/01-payments-api.yaml | jq -r '.[].score'
kubesec scan live/pod_audit-lab_payments-api.json | jq -r '.[].score'
```

Después diffeá las reglas que pasaron en cada uno:

```bash
diff <(kubesec scan manifests/01-payments-api.yaml \
        | jq -r '.[].scoring | (.passed//[])[].id' | sort) \
     <(kubesec scan live/pod_audit-lab_payments-api.json \
        | jq -r '.[].scoring | (.passed//[])[].id' | sort)
```

6. Limpieza:

```bash
kubectl delete ns audit-lab
```

**Preguntas de verificación**

- **Q8.1** — El objeto vivo puntuó *más alto* que el manifiesto fuente aunque no se endureció nada. Identificá al menos dos campos que el API server rellenó por defecto, y explicá qué reglas de Kubesec satisficieron gratis.
- **Q8.2** — Dado Q8.1, ¿un escaneo del objeto vivo es más o menos confiable que uno del manifiesto fuente? Enunciá con claridad qué mide cada uno y cuándo correrías cada uno.
- **Q8.3** — El pipeline de exportación borra `.status` y `.metadata.managedFields`. ¿Qué se rompe si dejás `managedFields`, y qué información relevante para seguridad contiene `.status` que *otro* tipo de auditoría querría?
- **Q8.4** — Tu exportación incluye objetos `Pod` propiedad de Deployments, así que cada carga de trabajo se cuenta dos veces. ¿Qué le hace eso al ranking de `uniq -c` del paso 3, y cómo filtrás los pods con dueño usando un solo predicado `jq`?
- **Q8.5** — Un webhook de admisión mutante (un inyector de service mesh) agrega un sidecar con `NET_ADMIN` en tiempo de admisión. ¿Cuál de tus dos objetivos de escaneo —manifiesto fuente o exportación viva— lo ve? ¿Qué prueba eso sobre los límites de cobertura del análisis estático pre-commit?
- **Q8.6** — En el paso 1, PSA puede haber rechazado el pod directamente. Si Pod Security Admission ya bloquea pods privilegiados en el API server, ¿cuál es el valor residual de correr Kubesec y KubeLinter en CI? Dá dos respuestas concretas.

---

## Ejercicio 9 — Simulacro a velocidad de examen (cronometrado: 12 minutos en total)

Hacé esto sin apuntes. Cada uno tiene la forma de una tarea del CKS.

1. **(3 min)** Un archivo `/opt/task/deploy.yaml` puntúa negativo. Usando `kubesec`, producí una lista de *solo* los IDs de reglas críticas, uno por línea, en `/opt/task/critical.txt`. Sin JSON, sin texto extra.

2. **(3 min)** Usando `kube-linter`, corré **solo** los checks `privileged-container`, `run-as-non-root` y `no-read-only-root-fs` contra `/opt/task/manifests/`, sin ningún check por defecto habilitado. Escribí el comando.

3. **(2 min)** Modificá `/opt/task/deploy.yaml` para que `kubesec scan` reporte un puntaje de **al menos 10** y cero hallazgos críticos. Enunciá el conjunto mínimo de campos que tenés que agregar.

4. **(2 min)** Determiná, sin descargar la imagen ni arrancar un contenedor, si `registry.example.com/app:2.1` corre como root.

5. **(2 min)** Un pod está trabado en `CreateContainerConfigError` con el evento `container has runAsNonRoot and image will run as root`. Dá los dos arreglos posibles y decí cuál elegirías en un clúster endurecido, y por qué.

**Preguntas de verificación**

- **Q9.1** — Para la tarea 2, ¿qué pasa si pasás `--include` sin deshabilitar los defaults? ¿Qué flag o clave de configuración evita que se agregue el conjunto por defecto?
- **Q9.2** — Para la tarea 3, ¿podrías llegar a un puntaje de 10 agregando solo `resources` y `serviceAccountName`? Mostrá la aritmética.
- **Q9.3** — Para la tarea 5, uno de los dos arreglos debilita la postura de seguridad del clúster. ¿Cuál, y cuál es el control exacto que estarías resignando?

---

## Referencia: lo que estas herramientas *no* ven

Grabate esta lista — es la diferencia entre un reporte y una evaluación.

| Punto ciego | Por qué el análisis estático no lo ve | Control complementario |
|---|---|---|
| Defaulting del API server | YAML fuente ≠ objeto admitido | Escanear la exportación viva (Ej. 8) o usar un webhook de admisión |
| Webhooks mutantes / inyección de sidecars | Ocurre después de CI | Política en tiempo de admisión (Kyverno, Gatekeeper) |
| RBAC otorgado al ServiceAccount | Otro objeto, a menudo en otro repo | `kubectl auth can-i --list --as=system:serviceaccount:ns:sa` |
| Ausencia de NetworkPolicy | No es un campo de la carga de trabajo | `kube-linter` no tiene check por defecto; usá Kyverno o una auditoría por namespace |
| CVEs dentro de la imagen | Requiere una base de datos de vulnerabilidades, no un motor de reglas | `trivy image`, Clair, Grype (CKS 4.3) |
| Abuso de syscalls en runtime | No es expresable estáticamente | Falco, seccomp `RuntimeDefault`, AppArmor |
| Secretos en Git | No es un campo de Kubernetes | `gitleaks`, `trivy fs --scanners secret` |
| Semántica de un `hostPath` | `/var/log` y `/` son ambos "un hostPath" | Kubesec solo trata como caso especial `docker.sock` — sigue haciendo falta revisión humana |

---

## Fuentes

- CKS Curriculum v1.34 — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubesec — https://kubesec.io/ y https://github.com/controlplaneio/kubesec
- Documentación de KubeLinter — https://docs.kubelinter.io/
- Referencia de checks de KubeLinter — https://docs.kubelinter.io/#/generated/checks
- Referencia de templates de KubeLinter — https://docs.kubelinter.io/#/generated/templates
- Código fuente de KubeLinter — https://github.com/stackrox/kube-linter
- Kubernetes — Configure a Security Context for a Pod or Container — https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- Kubernetes — Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Kubernetes — Pod Security Admission — https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Kubernetes — Restrict a Container's Access to Resources with AppArmor — https://kubernetes.io/docs/tutorials/security/apparmor/
- Kubernetes — Restrict a Container's Syscalls with seccomp — https://kubernetes.io/docs/tutorials/security/seccomp/
- Trivy — Misconfiguration scanning — https://trivy.dev/latest/docs/scanner/misconfiguration/
- Aqua Vulnerability Database (checks de Dockerfile DS002/DS026/DS031) — https://avd.aquasec.com/misconfig/
- OCI Image Specification — configuración de imagen — https://github.com/opencontainers/image-spec/blob/main/config.md
- skopeo — https://github.com/containers/skopeo
- go-containerregistry / crane — https://github.com/google/go-containerregistry/blob/main/cmd/crane/README.md

---

<details>
<summary><strong>Respuestas</strong> — expandí solo después de intentar cada bloque</summary>

### Ejercicio 0

**A0.1** — Que no haya kubeconfig significa que las herramientas operan sobre *archivos*, así que pertenecen lo más a la izquierda posible del pipeline: hook de pre-commit, check de pull request, etapa de build en CI — antes de que nada se aplique. El corolario es que nunca pueden detectar nada que solo exista en el clúster: defaulting del API server, webhooks de admisión mutantes (inyección de sidecars), el RBAC realmente asociado al ServiceAccount referenciado, NetworkPolicies del namespace, configuración a nivel de nodo, o drift introducido con `kubectl edit`. Analizan la *intención tal como está escrita*, no el *estado tal como corre*.

**A0.2** — `scan /dev/stdin` funciona porque la stdin del contenedor está conectada (`-i`) y kubesec acepta cualquier ruta legible; `/dev/stdin` es un descriptor de archivo hacia el YAML canalizado. La segunda forma falla porque `manifests/01-payments-api.yaml` es una ruta en el *host*, y el filesystem del contenedor no tiene tal archivo — necesitarías `-v "$PWD":/work:ro` y después `scan /work/manifests/01-payments-api.yaml`. Este es el error clásico de CLI containerizada y cuesta minutos de examen.

**A0.3** — `kube-linter checks list` (agregá `--format json | jq -r '.[].name'` para obtener los nombres pelados). El check es `privileged-container`. Los `--help` de ambas herramientas y los subcomandos `checks list` / `templates list` se autodocumentan; nunca necesitás documentación externa para el catálogo de checks.

---

### Ejercicio 1

**A1.1** — −30 −30 −9 −9 −9 −1 = **−88**, que coincide con `score`. El puntaje es una suma simple de los pesos de las reglas que matchearon: aditivo, sin cota, sin noción de explotabilidad, alcanzabilidad ni radio de impacto. Reportar "−88" a un responsable no significa nada — no tiene cota superior ni inferior y no es comparable entre manifiestos de formas distintas. Reportá en cambio los *IDs de reglas* y sus razones. El número solo sirve como señal monótona de regresión ("este PR lo empeoró").

**A1.2** — Las reglas de Kubesec son selectores booleanos independientes sobre el YAML; no hay grafo de dependencias, así que `privileged: true` y `capabilities.add: [SYS_ADMIN]` matchean cada una su propio selector y cobran cada una su propio peso. Técnicamente la segunda es redundante — `privileged` ya otorga el conjunto completo de capabilities, deshabilita el confinamiento de seccomp/AppArmor y da `/proc` sin enmascarar y todos los dispositivos. La lección: el scoring basado en reglas **cuenta dos veces los controles superpuestos**, así que los puntajes no son medidas aditivas de riesgo. Dos manifiestos con el mismo puntaje pueden tener exposiciones reales tremendamente distintas.

**A1.3** — Casi nada. `allowPrivilegeEscalation` controla el bit `no_new_privs`, que gobierna si un proceso puede ganar privilegios vía binarios setuid o file capabilities. Un contenedor `privileged: true` ya arranca con todas las capabilities, así que no hay nada *a lo que* escalar; de hecho el kubelet rechaza la combinación `privileged: true` con `allowPrivilegeEscalation: false` como inválida en muchas versiones. Ponerlo puramente para cosechar +7 movería el puntaje de −88 a −81 cambiando la postura de seguridad en cero. La lección: **un puntaje es un proxy, y todo proxy se puede gamear**. Bloqueá según la presencia de hallazgos críticos, no según el total (ver A7.1).

**A1.4** — La regla de AppArmor de Kubesec es un selector sobre una anotación del pod cuya *clave* embebe el nombre del contenedor: `container.apparmor.security.beta.kubernetes.io/<nombre-del-contenedor>`. El texto del selector de ejemplo impreso en la salida trae `nginx` hardcodeado porque así se escribió/documentó la regla; el motor matchea el prefijo de la anotación para el contenedor real. Nuestro pod no tiene ninguna anotación `container.apparmor...`, así que la regla queda en `advise` y no otorga nada. Además, esa forma de anotación está deprecada en Kubernetes ≥1.30 (ver A2.4).

**A1.5** — Con `set -e`, *cualquier* salida no-cero aborta el script, así que un bucle sobre manifiestos se detiene en el primer archivo que falla — obtenés una auditoría parcial que parece completa. Distinguir códigos importa porque "el escaneo corrió y encontró problemas" (un resultado de política que quizá quieras recolectar para todos los archivos) es categóricamente distinto de "el escáner no pudo parsear el archivo / se cayó / no está instalado" (una falla de herramienta que debe abortar ruidosamente). Kubesec usa deliberadamente 2 para falla de política, dejando el 1 libre para errores de uso/parseo — así que `--exit-code 0` te deja recolectar resultados y decidir vos mismo el desenlace de la compuerta a partir del JSON.

**A1.6** — Kubesec solo entiende tipos de carga de trabajo (Pod, Deployment, StatefulSet, DaemonSet y demás portadores de pod template). Ante un `Service` no devuelve puntaje cero — falla con salida no-cero y sin JSON usable. Operativamente, en un directorio mixto un bucle ingenuo o aborta (con `set -e`) o registra un resultado espurio. Toda compuerta real debe entonces filtrar primero por kind, o tolerar el error explícitamente y marcar el archivo como omitido — y *loguear* la omisión, porque una omisión silenciosa es la forma en que una carga de trabajo deja de escanearse sin que nadie se entere.

---

### Ejercicio 2

**A2.1** — `RunAsUser10000` requiere `runAsUser > 10000`, así que el UID 999 no pasa el selector. La razón es la **colisión de UIDs con el host**: los UIDs del contenedor son los mismos UIDs numéricos que en el host salvo que haya user namespaces en juego. Los UIDs bajos (< 1000, y comúnmente < 10000) chocan con cuentas de sistema reales del nodo — así que un proceso de contenedor corriendo como UID 999 posee los archivos creados en un montaje `hostPath` como el UID 999 del host, y gana acceso a cualquier recurso compartido del host que pertenezca a esa cuenta. Elegir un UID alto y poco probable de colisionar limita lo que puede tocar un escape de contenedor o una escritura en un volumen compartido.

**A2.2** — `drop: ["NET_RAW", "SYS_MODULE", "SYS_PTRACE"]` satisface `CapDropAny` (una lista de drop no vacía) pero no `CapDropAll` (que exige `ALL` en la lista). La forma más débil es legítima cuando el contenedor genuinamente necesita una capability que el conjunto por defecto del runtime provee — por ejemplo un agente de red que necesita `NET_BIND_SERVICE` para un puerto por debajo de 1024. La buena práctica sigue siendo `drop: ["ALL"]` seguido de un `add:` explícito de la única capability requerida, que es a la vez auditable y mínimo; una lista de drop curada a mano hereda en silencio cada capability por defecto que el runtime agregue en el futuro.

**A2.3** — `readOnlyRootFilesystem: true` remonta `/` como solo lectura dentro del contenedor. Casi todo proceso real escribe *en algún lado*: `/tmp`, un directorio de caché, un archivo PID, una cola de logs, el espacio de scratch de un runtime de lenguaje. Sin montajes `emptyDir` escribibles exactamente en esas rutas, el proceso falla al arrancar o en la primera escritura con `EROFS` — típicamente `open /tmp/xxx: read-only file system`, visible como `CrashLoopBackOff` con el error en `kubectl logs`. El control solo es adoptable si lo emparejás con un conjunto explícito y enumerado de montajes escribibles — lo cual ya es valioso en sí, porque te obliga a saber qué escribe tu carga de trabajo.

**A2.4** — Kubernetes 1.34 honra **`securityContext.appArmorProfile`** (el campo, GA desde 1.30); la anotación `container.apparmor.security.beta.kubernetes.io/<c>` está deprecada y encaminada a su remoción. La regla `ApparmorAny` de Kubesec mira la **anotación**. La respuesta correcta *no* es agregar una anotación deprecada para farmear puntos: corregí el manifiesto al campo soportado, y corregí el *escáner* — actualizálo, abrí un issue, o agregá una regla personalizada/exención. Escribir superficie de API deprecada en los manifiestos para satisfacer a un linter es cómo se acumula deuda de migración que rompe en la próxima actualización del clúster. Este es el ejemplo canónico de **retraso del escáner**, y es por eso que nunca tratás el ruleset de un escáner como si fuera la política — la política es el estándar; el escáner es una implementación imperfecta de él.

**A2.5** — No, no necesariamente. La carga de 22 puntos ganó +3 por una anotación de AppArmor deprecada (que puede ni siquiera aplicarse en un clúster 1.34) y +2 por propiedades de PVC que son preocupaciones de disponibilidad de almacenamiento, no controles de seguridad. Mientras tanto, podría estar sin `automountServiceAccountToken: false` o estar fijada a `:latest`. El puntaje es **una suma de reglas que matchearon, no una medición de riesgo**: no tiene denominador, ni ponderación por explotabilidad, ni conciencia de los controles para los que no tiene reglas. Las comparaciones entre cargas de trabajo distintas no significan nada; solo el delta sobre la *misma* carga a lo largo del tiempo lleva señal.

**A2.6** — Elimina la proyección automática de un token de ServiceAccount en `/var/run/secrets/kubernetes.io/serviceaccount/token`. Ese token es lo más valioso que un atacante encuentra tras comprometer un contenedor: es una credencial válida contra el API server, y combinado con RBAC demasiado amplio convierte un pod comprometido en acceso a todo el clúster. Kubesec otorga cero puntos porque no tiene una regla para eso. El principio: **el ruleset del escáner no es la política**. Un programa que solo arregla lo que el escáner marca va a perderse sistemáticamente todo control para el que la herramienta no tiene regla, y el ruleset lo eligen los mantenedores de la herramienta, no tu modelo de amenazas.

**A2.7** — Un pin por digest derrota la **mutación de tags**: un atacante (o un job de CI descuidado) con permiso de push al registry puede reapuntar `:v1.2.3` o `:latest` a otra imagen, y cada pull posterior — incluido el reinicio de un nodo o un evento de reprogramación — corre en silencio la imagen sustituida. Un digest es direccionado por contenido y no se puede reapuntar. De las dos herramientas, **KubeLinter** marca esto, vía el check no-default `latest-tag` (que habilitaste en el Ejercicio 5); Kubesec no tiene ninguna regla sobre referencias de imagen.

---

### Ejercicio 3

**A3.1** — Sin `--exit-code 0`, kubesec devuelve 2 en el primer manifiesto que falla. Bajo `set -e` el script aborta ahí, así que ves resultados de un solo archivo y un estado de salida que sugiere un crash. `|| true` sobre la llamada a `kubesec` no alcanza por sí solo porque `set -o pipefail` también está activo: en un pipeline como `kubesec scan "$f" | jq ...`, un estado no-cero de *kubesec* se propaga como el estado del pipeline aunque `jq` haya tenido éxito, y un `|| true` puesto después del pipeline entero también enmascara fallas genuinas de `jq`. La solución limpia es lo que hace el script: capturar la salida de kubesec con `--exit-code 0` (así 0 significa "corrió correctamente") y después evaluar la decisión de política desde el JSON.

**A3.2** — Divulgaste el manifiesto completo: hostnames de registry y nombres de repositorio, nombres de contenedor y de pod, namespace, nombre del ServiceAccount, los *nombres* de las variables de entorno (y cualquier valor puesto inline en el manifiesto — que frecuentemente incluye credenciales en repos reales), rutas de volúmenes, node selectors y, por inferencia, tu topología interna de servicios. Es aceptable para manifiestos de ejemplo públicos, material de capacitación y charts de código abierto. No es aceptable para nada que describa producción. La remediación directa es exactamente el paso 3: correr `kubesec http 8080` localmente (o como un Deployment dentro de tu propio clúster) y apuntar el mismo `curl` ahí — API idéntica, salida idéntica, sin egreso.

**A3.3** — Primero, **la validación basada en puntaje no es política determinista**: el límite de aprobación/rechazo es un entero arbitrario, y agregar reglas positivas no relacionadas (resources, serviceAccountName) puede levantar un objeto genuinamente peligroso por encima de la línea. Segundo, **el ruleset no está versionado junto con tu política**: una actualización de kubesec puede cambiar en silencio valores de puntos y dar vuelta decisiones de admisión para objetos que no cambiaron, lo que es un incidente de disponibilidad. Además no ofrece alcance por namespace/label, ni modo dry-run/auditoría, ni excepciones por objeto, ni forma de expresar "advertir en staging, imponer en prod". PSA (incorporado, basado en estándares, tres modos: `enforce`/`audit`/`warn`, con alcance por namespace) y Kyverno/Gatekeeper (políticas declarativas, testeables, versionadas, con exclusiones) están diseñados para ese trabajo.

**A3.4** — Sí, pueden. +1 request de CPU, +1 request de memoria, +1 límite de CPU, +1 límite de memoria, +1 serviceAccountName, +7 allowPrivilegeEscalation… un pod privilegiado puede acumular positivos y aun así quedar por debajo de cero en total, pero en un manifiesto *menos* catastrófico (digamos, solo `hostPID: true` en −9) el relleno cruza fácilmente un umbral de +10. El rediseño: **fallar si `scoring.critical` no está vacío, sin importar el puntaje** — o sea `(( crit > 0 )) && fail`, con el umbral numérico aplicado solo como condición adicional y secundaria. Eso es exactamente lo que hace la compuerta del Ejercicio 7.

**A3.5** — kubesec emite un objeto JSON de error que no es un array (o nada en absoluto) para tipos no soportados y errores de parseo. `jq -r '.[] | ...'` sobre algo que no es un array o bien tira error a stderr (descartado) o bien no produce líneas; el bucle `while read` itera cero veces, `rc` queda en 0, y el archivo se reporta silenciosamente como limpio. La guarda `jq -e 'type=="array" and length>0'` convierte eso en una línea explícita de `SKIP`. **Un archivo omitido debe quedar logueado**, porque "sin hallazgos" y "no escaneado" son indistinguibles en un resumen y lo segundo es cómo la cobertura se pudre en silencio.

---

### Ejercicio 4

**A4.1** — Las dos herramientas implementan rulesets distintos y solo parcialmente superpuestos, derivados de modelos de amenaza distintos: Kubesec es un scorer de seguridad de pods curado a mano; KubeLinter es un motor general de checks sobre objetos de Kubernetes que además cubre confiabilidad y consistencia entre objetos. Ninguno es superconjunto del otro, y ninguno es completo. La política correcta es correr **ambos** (más un motor de policy-as-code como `trivy config`/Checkov/Kyverno CLI para los checks que ninguno cubre), unir los hallazgos y tratar la *unión* como la línea base — recordando que la unión sigue sin ser la política. Apoyarse en un solo escáner es adoptar la opinión de un único proveedor sobre qué importa como si fuera tu programa de seguridad.

**A4.2** — *A favor:* una carga de trabajo sin límites de recursos es un vector de denegación de servicio — un pod puede matar de hambre a todos sus vecinos en el nodo, y un límite de memoria faltante convierte una fuga de memoria (o un ataque de amplificación de memoria) en desalojos a nivel de nodo. Sin probes, un contenedor comprometido o colgado sigue recibiendo tráfico. La disponibilidad es parte de la tríada CIA, así que bajo una lectura amplia son checks de seguridad. *En contra:* mezclarlos en una compuerta de seguridad produce ruido de alto volumen y baja severidad que entrena a los desarrolladores a ignorar la compuerta y presiona a los equipos a otorgar exenciones generales — que después también eximen los hallazgos reales. La resolución práctica son dos compuertas con semánticas de bloqueo distintas: los hallazgos de seguridad bloquean el merge; los de confiabilidad advierten o bloquean solo en un check de confiabilidad separado.

**A4.3** — `CAP_NET_RAW` permite abrir sockets raw y packet: fabricar paquetes arbitrarios, spoofing de ARP, spoofing de DNS, sniffear tráfico en la interfaz del pod y tunelizar por ICMP para exfiltración. Está en el conjunto de capabilities *por defecto* del runtime de contenedores, así que todo contenedor la tiene salvo que se la quite explícitamente — que es exactamente por qué merece un check dedicado: el estado peligroso es el default. Con `hostNetwork: true` el pod comparte el network namespace del *nodo*, así que quitar `NET_RAW` limita la fabricación de paquetes pero el contenedor sigue viendo y pudiendo bindear todas las interfaces del host, alcanzar servicios ligados al loopback del host (el puerto de solo lectura del kubelet, endpoints de metadata locales al nodo, interfaces de administración solo en `127.0.0.1`) y saltearse NetworkPolicy por completo — porque NetworkPolicy selecciona pods por su propia identidad de red, que un pod con host-network no tiene.

**A4.4** — `no-liveness-probe` y `no-readiness-probe` — el manifiesto endurecido no define ninguno de los dos. (Según tu versión, quizá veas también satisfechos los checks de la familia `unset-cpu-requirements`, ya que el manifiesto define los cuatro campos de recursos.) Un pod endurecido en seguridad falla una corrida por defecto porque el conjunto por defecto de KubeLinter es un conjunto de *buenas prácticas generales*, no un conjunto de seguridad. Esta es la motivación concreta del Ejercicio 5: hay que curar el conjunto de checks para que coincida con el propósito de la compuerta, o la relación señal/ruido la vuelve inservible.

**A4.5** —
```bash
kube-linter lint --config .kube-linter.yaml manifests/; rc=$?; (( rc > 1 )) && { echo "TOOLING ERROR"; exit 2; }; (( rc == 1 )) && findings=1
```
El principio distintivo: KubeLinter usa **1** para "se encontraron errores de lint" y reserva códigos mayores para errores de uso/internos; un binario faltante da **127** desde el shell, y un proceso terminado por señal da 128+N. Así que `rc == 1` es un resultado de política y `rc > 1` es una falla de herramienta. Nunca los colapses.

**A4.6** — Sin `metadata.namespace`, KubeLinter imprime `<no namespace>/payments-api`. Esto importa al diffear porque el mismo chart renderizado para `staging` y para `prod` produce identificadores de objeto distintos, así que un diff textual ingenuo de dos reportes muestra todas las líneas como cambiadas. Normalizá por nombre del check más nombre del objeto (o linteá la fuente sin namespace y dejá que el overlay lo defina) antes de diffear — y preferí la salida JSON/SARIF, donde los campos son separables, por sobre la forma en texto plano.

---

### Ejercicio 5

**A5.1** — `addAllBuiltIn: true` + `exclude` es **fail-closed**: cuando la herramienta agrega un check nuevo en el próximo release, lo recibís automáticamente y tenés que decidir conscientemente descartarlo. La forma aditiva `include` es **fail-open**: los checks nuevos nunca se disparan, así que tu cobertura se congela silenciosamente en el día que escribiste la configuración, y nadie lo nota por dos años. Lo sustractivo es el default correcto para una línea base de seguridad. La forma aditiva es correcta cuando la compuerta tiene un propósito estrechamente definido — por ejemplo un job dedicado de "cadena de suministro" que corre solo `latest-tag`, `env-var-secret` y `privileged-container` y está deliberadamente separado del job de línea base amplio.

**A5.2** — KubeLinter detecta un directorio de chart (vía `Chart.yaml`) y **renderiza los templates él mismo** con los valores por defecto del chart antes de lintear, así que consume charts de Helm de forma nativa. Kubesec es un parser de YAML plano sin motor de plantillas: `{{ .Release.Name }}` no es YAML válido, así que el parseo falla. La regla general: **KubeLinter puede ir antes del renderizado; Kubesec debe ir después.** En un pipeline de Helm, corré `helm template` una vez y alimentá la salida renderizada a Kubesec (e, idealmente, también a KubeLinter, para que ambas herramientas vean la misma entrada).

**A5.3** — Tu compuerta reporta **limpio**, porque linteó el chart con los defaults de `values.yaml`, y el sidecar privilegiado solo aparece cuando se aplica `values-prod.yaml`. Este es un agujero de cobertura disfrazado de build en verde. El arreglo es renderizar y escanear **cada combinación de values que realmente desplegás**: iterá sobre `values-*.yaml`, corré `helm template -f values-<env>.yaml` y aplicá la compuerta a cada salida renderizada por separado. El mismo razonamiento vale para Kustomize: escaneá los overlays renderizados, no la base.

**A5.4** — `DeploymentLike` es el grupo incorporado de tipos de objeto de KubeLinter que cubre los objetos que llevan un pod template: Deployment, DaemonSet, StatefulSet, ReplicaSet, ReplicationController, Job, CronJob y Pods pelados. Así que tanto un `Pod` pelado como un `CronJob` **están** en alcance y van a ser verificados. (Si querés restringir un check a un conjunto más angosto, listá los kinds explícitos en vez del grupo; `objectKinds: ["Any"]` amplía a todos los objetos, incluidos Services y ConfigMaps.)

**A5.5** — Sí, sigue valiendo la pena imponerlo. Lo que protege el pin por digest en el overlay de CD es el artefacto *desplegado*; lo que protege `latest-tag` en el manifiesto fuente es todo lo que consume el manifiesto *sin* el overlay — un `kubectl apply` local, el clúster kind de un desarrollador, una restauración de recuperación ante desastres, un fragmento copiado y pegado durante un incidente. Más importante aún: el objetivo de un atacante es encontrar el único camino que saltea el camino endurecido. Defensa en profundidad significa que el patrón inseguro no debería existir en el repo en absoluto, para que ningún camino pueda tomarlo. También es una señal de lint fuerte para los revisores: un `:latest` en un diff es un marcador confiable de que el cambio esquivó el pipeline estándar.

**A5.6** — Los checks entre objetos necesitan el **conjunto completo de objetos en una sola invocación de lint**. `dangling-service` pregunta "¿alguna carga de trabajo matchea el selector de este Service?" y `non-existent-service-account` pregunta "¿existe en este conjunto el ServiceAccount referenciado?". Con `pass_filenames: true`, pre-commit pasa solo los archivos *modificados*, así que una corrida de lint podría ver el Service pero no su Deployment (o viceversa) y emitir falsos positivos — o, peor, ver solo el Deployment y pasar por alto un Service genuinamente colgado. `pass_filenames: false` más una regex `files:` significa "corré el directorio entero cada vez que algo en él cambie", lo cual es correcto y, para un linter tan rápido, barato.

---

### Ejercicio 6

**A6.1** — Un `Config.User` vacío significa que la imagen no declara ninguna instrucción `USER`, así que el contenedor corre como **UID 0 (root)** dentro de su namespace salvo que el `securityContext` del pod lo sobrescriba. Es el campo individual de mayor valor porque te dice la postura *por defecto* de toda carga de trabajo construida a partir de esa imagen, en todos los clústeres y todos los equipos — y porque es el campo que más seguido está mal: las imágenes base upstream (nginx, postgres, la mayoría de los runtimes de lenguajes) frecuentemente van por defecto a root, y todo Dockerfile derivado que se olvida del `USER` lo hereda. Un barrido de este único campo sobre todo el registry encuentra riesgo sistémico en minutos.

**A6.2** — La falla ocurrió en la **creación del contenedor**, antes de que el entrypoint de la imagen se ejecutara — el **kubelet** comparó el UID efectivo de la config de la imagen contra el `runAsNonRoot: true` del pod y se negó a crear el contenedor. De ahí `CreateContainerConfigError` en vez de un bucle de caídas. `runAsNonRoot: true` solo es insuficiente porque es apenas un *predicado*, no una asignación: acepta cualquier UID distinto de cero que la imagen declare. Si la imagen pone `USER 1` (o un UID que colisiona con una cuenta de sistema del host, o un UID que posee archivos en un `hostPath` compartido), el check pasa mientras la propiedad de seguridad que querías no se cumple. Fijá `runAsUser` explícitamente a un UID conocido, alto y sin colisiones, y mantené `runAsNonRoot: true` como aserción de refuerzo.

**A6.3** — **Sí, el token sigue siendo recuperable.** Cada instrucción del Dockerfile crea una capa; borrar un archivo en una capa posterior solo agrega una entrada whiteout — la capa anterior sigue conteniendo los bytes y se distribuye con la imagen. Cualquiera que la descargue puede extraer el tarball de la capa y leer `/tmp/.npmrc`. (La forma `RUN echo … && npm ci && rm …` en una sola instrucción sí evita *este* caso puntual, ya que los tres comandos corren en una capa — pero el mismo secreto típicamente también termina en `~/.npm/_logs`, en la caché de build y en la cadena `history[].created_by`, que está en texto plano en la config de la imagen.) La solución correcta son los **secret mounts de BuildKit**: `RUN --mount=type=secret,id=npmtoken …`, que expone el secreto en `/run/secrets/npmtoken` solo mientras dura esa instrucción y nunca lo escribe en ninguna capa ni en la historia. Los builds multi-stage que descartan la etapa de construcción son una mitigación parcial pero no ayudan si el secreto termina en la etapa final.

**A6.4** — **El check del manifiesto puede equivocarse, en la dirección insegura.** El `run-as-non-root` de KubeLinter inspecciona solo el YAML: un manifiesto que no define `runAsUser`/`runAsNonRoot` es marcado, y uno que sí los define no lo es — pero un manifiesto puede quedarse *callado* sobre el usuario y aun así desplegarse desde una imagen cuyo `USER` es root, y ningún check que razona solo sobre campos declarados puede ver eso. Concretamente: un Deployment con `securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}, readOnlyRootFilesystem: true}` — sin `runAsUser`, sin `runAsNonRoot` — parece bien endurecido a un lector casual, pasa varios checks, y corre como **UID 0** si la imagen es `FROM ubuntu` sin `USER`. Solo el análisis del lado de la imagen (`crane config … .config.User`) o un control de admisión que imponga `runAsNonRoot` cierra esa brecha. `trivy config Dockerfile` no puede equivocarse sobre el usuario declarado por la imagen, pero no dice nada sobre cómo el pod lo sobrescribe.

**A6.5** — `EXPOSE` es **puro metadato**. No abre un puerto, no crea un listener, y en Kubernetes se ignora por completo — el kubelet nunca lo lee, y la alcanzabilidad la determina lo que el proceso realmente bindea más el network namespace del pod y cualquier NetworkPolicy. Así que una imagen con `EXPOSE 22` puede no correr ningún demonio SSH, y una imagen sin `EXPOSE` puede correr uno. Es una señal débil en ambas direcciones — una pista de documentación. El check `ssh-port` de KubeLinter sobre manifiestos es algo más fuerte porque `containerPort: 22` al menos refleja una declaración deliberada del autor de la carga de trabajo, pero *también* es solo metadato; la respuesta autoritativa requiere inspección en runtime o una NetworkPolicy que niegue el puerto de plano.

**A6.6** — Listá cada repositorio y tag (`crane ls <repo>` / la API de catálogo del registry), y después, para cada referencia, corré `crane config <ref> | jq -r '.config.User'` y reportá toda imagen donde el valor sea vacío, `"0"` o `"root"`. Paraleliza trivialmente, solo necesita credenciales de lectura del registry, y nunca descarga una capa — `crane config` trae únicamente el manifiesto y el pequeño blob de configuración. Le gana a esperar un rechazo de admisión porque: es **proactivo** (encontrás las 40 imágenes root antes de que alguien intente desplegarlas en un namespace restringido, en lugar de descubrirlas de a un incidente de producción por vez); es **completo** (la admisión solo te informa sobre imágenes que alguien intentó correr hoy, en namespaces que casualmente imponen la política); y te da una **lista de trabajo de remediación** cuyos dueños son los mantenedores de las imágenes, en vez de un torrente de fallas de despliegue cuyo dueño es quien esté de guardia.

---

### Ejercicio 7

**A7.1** — Un hallazgo crítico es una afirmación categórica — "esta carga de trabajo puede escapar al host" — mientras que el puntaje es una suma sin cota donde positivos no relacionados lo compensan. Bloquear por críticos es por lo tanto más estricto y más explicable. El manifiesto que derrota una compuerta de puro umbral: tomá un pod con `hostPID: true` (−9) y agregale `allowPrivilegeEscalation: false` (+7), los cuatro campos de recursos (+4), `serviceAccountName` (+1), `readOnlyRootFilesystem` (+1), `runAsNonRoot` (+1), `runAsUser: 20001` (+1), `capabilities.drop: [ALL]` (+2), `seccompProfile` (+1) — total **+9**, cómodamente por encima de un umbral `MIN_SCORE=5`, mientras el pod aún puede leer el entorno de todos los procesos y `/proc` en el nodo.

**A7.2** — Si ambos devuelven 1, un escáner roto es indistinguible de un repo limpio pero ruidoso — y la inversión mucho más peligrosa es que un escáner *silenciosamente ausente* o *que se cae* produzca el mismo estado que un escaneo aprobado si el script se traga los errores. La compuerta entonces reporta verde sin realizar análisis alguno, a veces durante meses. Códigos distintos le permiten al pipeline enrutar los dos desenlaces de forma diferente: los hallazgos de política van al PR como comentarios de revisión y bloquean el merge; los errores de herramienta paginan al equipo de plataforma y hacen fallar el build con otro mensaje. "La compuerta estaba en verde porque nunca corrió" es la falla canónica de seguridad en CI.

**A7.3** — Controles aceptables: (1) **la exención vive en el diff**, así que pasa por la misma revisión de código que el riesgo que excusa — un segundo ingeniero debe aprobarla, y la anotación es grepeable en todo el repo para auditoría; (2) **CODEOWNERS sobre el patrón de la anotación**, de modo que la revisión del equipo de seguridad sea obligatoria para cualquier archivo que agregue una anotación `ignore-check.kube-linter.io/*`, más una justificación requerida y una fecha de vencimiento impuesta por un job periódico que reporta exenciones vencidas. No aceptable: **la autoaprobación** — el autor que agrega tanto el contenedor privilegiado como su exención en el mismo PR mergeado por él mismo, sin segunda parte y sin vencimiento. Eso no es un proceso de exención; es un opt-out.

**A7.4** — Depende del **alcance del check**. Los checks que evalúan la *pod spec* (`privileged-container`, `run-as-non-root`, `no-read-only-root-fs`) evalúan el pod template, así que la anotación va en `spec.template.metadata.annotations`. Los checks que evalúan el *objeto de nivel superior* (`required-label` sobre el Deployment, `minimum-three-replicas`, `mismatching-selector`) la necesitan en el `metadata.annotations` propio del Deployment. Ante la duda, ponéla donde vive el objeto identificado en la línea `(object: ns/name Kind=...)` del hallazgo — ese es el objeto que el check matcheó.

**A7.5** — Kubesec es todo o nada por archivo, así que particionás. Opciones, la mejor primero: (1) **segregar por directorio** — mantené el pequeño conjunto de cargas de infraestructura legítimamente privilegiadas en `manifests/privileged/` con su propia compuerta que verifique un *conjunto exacto esperado* de hallazgos críticos (para que un hallazgo crítico *nuevo* sobre el DaemonSet CSI siga fallando), mientras `manifests/` corre la compuerta estricta; (2) **mantener un archivo de línea base de hallazgos esperados** y diffear los IDs críticos actuales contra él, fallando solo ante agregados — la misma técnica que se usa para suprimir hallazgos conocidos en cualquier escáner sin sintaxis de exención; (3) la peor, **excluir el archivo por ruta** en el script de la compuerta, que es un instrumento romo que además te ciega ante futuras regresiones en ese archivo. En todos los casos registrá *por qué*, con un responsable y un vencimiento, junto a la exclusión.

**A7.6** — Tiene que correr sobre la **salida renderizada que Argo CD realmente aplica** — es decir `kustomize build overlays/prod` (o `helm template` con los values de producción), en un check pre-merge sobre el repo GitOps, e idealmente otra vez como hook de pre-sync o como política de admisión en el clúster. Lintear solo los manifiestos base no significa nada cuando un overlay puede parchear `securityContext.privileged: true` en cualquier contenedor. La falla que previene es el **bypass por overlay/parche** — endurecer la base mientras el parche específico del entorno lo deshace calladamente, que es la forma más común en que una compuerta de análisis estático aprobada convive con una carga de trabajo privilegiada en producción.

---

### Ejercicio 8

**A8.1** — El API server rellena por defecto una gran cantidad de campos en la admisión. Los dos que más importan para el ruleset de Kubesec: **`spec.serviceAccountName: default`** se completa aun cuando el manifiesto lo omite, satisfaciendo la regla `ServiceAccountName` por +1; y, según la configuración del clúster, **`spec.securityContext.seccompProfile.type: RuntimeDefault`** puede ser establecido por la feature `SeccompDefault` del kubelet o por una política mutante, satisfaciendo `SeccompAny` por +1. (Otros defaults — `terminationGracePeriodSeconds`, `dnsPolicy`, `restartPolicy`, `imagePullPolicy`, `schedulerName` — no mapean a reglas pero sí cambian el objeto.) Así que el objeto vivo puntúa más alto por razones que reflejan los defaults del API server, no la intención del autor.

**A8.2** — Miden cosas distintas y ninguno domina al otro. El **escaneo de la fuente** mide *la intención del autor y la higiene del repositorio* — es la entrada correcta para una compuerta de merge, porque es sobre lo que un revisor puede actuar y lo que van a heredar las futuras copias del manifiesto. El **escaneo vivo** mide *la postura efectiva* — es la entrada correcta para una auditoría de clúster y un reporte de cumplimiento, porque incluye el defaulting, los webhooks mutantes y cualquier drift manual. Un `serviceAccountName: default` ganado por defaulting del API es *peor* seguridad que un ServiceAccount de mínimo privilegio nombrado explícitamente, y sin embargo puntúa igual — así que un escaneo vivo puede halagar a un clúster. Corré ambos: la fuente en CI, el vivo de forma programada, y tratá una divergencia entre ellos como un hallazgo en sí mismo.

**A8.3** — `metadata.managedFields` es contabilidad de server-side apply: decenas de kilobytes de metadatos anidados de propiedad de campos por objeto. Dejarlo infla enormemente la exportación, ralentiza ambos escáneres y —como embebe rutas de campos como claves de mapa— puede confundir selectores y volver ilegibles los diffs. `.status` se descarta porque no es parte del estado deseado, pero es exactamente lo que quiere *otra* auditoría: `status.podIP`, `status.hostIP` y `status.nodeName` para mapear el radio de impacto, `status.containerStatuses[].imageID` para el **digest de la imagen realmente en ejecución** (que es la verdad de campo para correlacionar vulnerabilidades — el tag del `spec` puede haber sido reapuntado desde que el pod arrancó), y `status.qosClass`. El análisis estático del estado deseado y el análisis forense del estado observado son pasadas separadas con entradas separadas.

**A8.4** — Cada pod creado por un Deployment se exporta tanto como parte del pod template del Deployment *como* objeto Pod independiente, así que cada hallazgo se cuenta al menos dos veces (tres a través del ReplicaSet si también los exportás). El ranking de `uniq -c` queda inflado por un factor aproximadamente constante, lo cual es inofensivo para el *orden* pero muy engañoso para cualquier conteo absoluto que pongas en un reporte. Filtrá con un predicado de propiedad: `jq -c '.items[]? | select(.metadata.ownerReferences == null)'` — quedate solo con los pods sin controlador dueño (pods genuinamente independientes, que de por sí ameritan ser marcados) y dejá que los objetos controladores den cuenta del resto.

**A8.5** — Solo la **exportación viva** ve el sidecar inyectado. El manifiesto fuente en Git no tiene tal contenedor; el webhook mutante del mesh lo agrega en tiempo de admisión, después de que toda compuerta de CI ya pasó. Esto prueba el límite duro de cobertura del análisis estático pre-commit: **analiza el objeto que escribiste, no el objeto que corre.** Cualquier cosa inyectada por un webhook mutante — proxies de service mesh, sidecars de logging, init containers inyectores de secretos, volúmenes de agentes de nodo — le es invisible, y esos contenedores inyectados son frecuentemente lo más privilegiado del pod (`NET_ADMIN` para configurar iptables, montajes `hostPath`, UID root). Cerrar la brecha requiere o escanear objetos vivos de forma programada o imponer en admisión, después de la mutación.

**A8.6** — Dos respuestas concretas. (1) **Cobertura de lo que PSA no verifica.** PSA implementa solo los Pod Security Standards: privilegios, capabilities, namespaces del host, tipos de volumen, seccomp/AppArmor. No dice nada sobre tags `:latest`, límites de recursos faltantes, `automountServiceAccountToken`, probes faltantes, Services colgados, secretos hardcodeados en variables de entorno, ni la etiqueta `owner` de tu organización — todo lo cual KubeLinter y Kubesec sí cubren. (2) **Economía del feedback shift-left y aplicación no uniforme.** Un rechazo en tiempo de `kubectl apply`/sync de Argo se descubre tarde, por quien esté desplegando, a menudo fuera de horario y después de un build en verde — mientras que un hallazgo de CI lo descubre el autor, en el PR, con una cadena de remediación adjunta. Y PSA se impone *por namespace*: cualquier namespace sin etiqueta `enforce`, y todo clúster de la flota que todavía no fue etiquetado, no tiene protección alguna — CI los cubre uniformemente. Además, PSA no tiene concepto de un estándar *organizacional* solo de advertencia más allá de los tres niveles incorporados, y no puede expresar checks personalizados en absoluto.

---

### Ejercicio 9

**Tarea 1:**
```bash
kubesec scan --exit-code 0 /opt/task/deploy.yaml \
  | jq -r '.[].scoring.critical[]?.id' > /opt/task/critical.txt
```
(El `?` sobre `critical[]` evita un error si el array no está presente.)

**Tarea 2:**
```bash
kube-linter lint --do-not-auto-add-defaults \
  --include privileged-container \
  --include run-as-non-root \
  --include no-read-only-root-fs \
  /opt/task/manifests/
```
Forma equivalente en archivo de configuración (más confiable entre versiones — verificá los nombres de flags con `kube-linter lint --help`):
```yaml
checks:
  doNotAutoAddDefaults: true
  include: ["privileged-container", "run-as-non-root", "no-read-only-root-fs"]
```

**Tarea 3:** Eliminá todo disparador crítico (`privileged`, `capabilities.add`, `hostNetwork`, `hostPID`, `hostIPC`, cualquier hostPath a `docker.sock`) y agregá, como mínimo: `allowPrivilegeEscalation: false` (+7) y los cuatro campos de `resources` (+4). Eso da **11** — por encima del umbral y con cero críticos. En la práctica agregá también `capabilities.drop: ["ALL"]` (+2), `readOnlyRootFilesystem: true` (+1), `runAsNonRoot: true` (+1), `runAsUser: 20001` (+1), `serviceAccountName` (+1) y `seccompProfile.type: RuntimeDefault` (+1) — porque el punto de la tarea es la postura, no el número.

**Tarea 4:**
```bash
skopeo inspect --config docker://registry.example.com/app:2.1 | jq -r '.config.User'
# or
crane config registry.example.com/app:2.1 | jq -r '.config.User'
```
Cadena vacía, `"0"` o `"root"` ⇒ corre como root.

**Tarea 5:** O bien (a) reconstruir la imagen con una instrucción `USER <uid-no-root>` (y hacer `chown` de las rutas que necesite), o bien (b) definir `runAsUser: <distinto de cero>` explícitamente en el `securityContext` del pod para que el kubelet tenga un UID no-root concreto y ya no necesite consultar la imagen. En un clúster endurecido elegí **(a)**, arreglar la imagen: hace que la carga de trabajo sea segura en todos lados donde se despliegue, incluidos clústeres y namespaces que no imponen `runAsNonRoot`, y elimina la posibilidad de que un manifiesto futuro omita la sobrescritura. (b) es la mitigación *inmediata* correcta mientras la reconstrucción de la imagen está en curso, y ambas juntas son mejores que cualquiera por separado. Notá que (a) igual requiere que los archivos de la imagen sean legibles/escribibles por el nuevo UID — que es exactamente el trabajo que hace que los equipos recurran a la sobrescritura en el manifiesto.

**A9.1** — Si pasás `--include` sin deshabilitar los defaults, el conjunto de checks por defecto igual se agrega y tus tres checks se *suman encima* — obtenés todo el ruido por defecto más los extras, que no es lo que pedía la tarea. `--do-not-auto-add-defaults` (CLI) / `checks.doNotAutoAddDefaults: true` (configuración) suprime el conjunto por defecto para que `include` sea la lista completa.

**A9.2** — No. `resources` da +4 (requests de cpu/memoria, límites de cpu/memoria) y `serviceAccountName` da +1, para un total de **+5** — lejos de 10. Necesitás `allowPrivilegeEscalation: false` (+7) para superarlo cómodamente, o la combinación de `capabilities.drop: ["ALL"]` (+2), `readOnlyRootFilesystem` (+1), `runAsNonRoot` (+1) y `runAsUser > 10000` (+1) para llegar exactamente a 10. Hacer la aritmética a partir de la salida `scoring[].points` de la propia herramienta —y no de memoria— es la habilidad transferible, ya que los pesos difieren según la versión.

**A9.3** — El arreglo (b), definir `runAsUser` en el manifiesto, es la opción más débil *si se usa como arreglo permanente*: la imagen sigue trayendo un default root, así que la propiedad de seguridad depende enteramente de que todo manifiesto futuro se acuerde de la sobrescritura. Lo que resignás es la **defensa en profundidad en la capa del artefacto** — la garantía de que la carga de trabajo es segura sin importar cómo se despliegue. Cualquier camino de despliegue que saltee tus plantillas endurecidas (un `kubectl run` de depuración, otro equipo reutilizando la imagen, una restauración de DR desde un manifiesto viejo) la corre como root.

</details>