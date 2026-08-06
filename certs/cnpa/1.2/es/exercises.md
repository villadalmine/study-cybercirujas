# Ejercicios guiados — Tema 1.2: DevOps Practices and Culture in Platform Engineering

> **Requisitos previos**: una terminal Linux/macOS con `git`, `docker`, `kind`, `kubectl` y `curl`. Los ejercicios 1–3 no necesitan cluster; el ejercicio 4 crea uno local con `kind`. Todos los pasos son idempotentes: si algo falla, podés borrar el directorio o el cluster y empezar de nuevo.

---

## Ejercicio 1 — Medir las DORA metrics desde el historial de Git

Las cuatro métricas DORA (*deployment frequency*, *lead time for changes*, *change failure rate*, *failed deployment recovery time*) son el estándar de facto para medir el rendimiento de entrega de software, y el CNPA espera que sepas qué mide cada una y cómo se obtiene. En este ejercicio construís un repositorio sintético con fechas controladas y calculás las cuatro métricas con comandos reales.

**1.** Creá el repositorio con identidad local (no toca tu configuración global):

```bash
mkdir dora-lab && cd dora-lab
git init -b main
git config user.email "student@example.com"
git config user.name "CNPA Student"
```

**2.** Simulá el primer release. El commit representa el momento en que el cambio se integra a `main`; el *annotated tag* representa el deploy a producción. Forzamos las fechas con `GIT_AUTHOR_DATE` / `GIT_COMMITTER_DATE` para que la salida sea determinística:

```bash
export GIT_AUTHOR_DATE="2026-07-01T09:00:00" GIT_COMMITTER_DATE="2026-07-01T09:00:00"
echo "feature A" > app.txt
git add app.txt && git commit -m "feat: checkout flow"
GIT_COMMITTER_DATE="2026-07-03T15:00:00" git tag -a v1.0.0 -m "deploy v1.0.0"
```

**3.** Segundo release: un cambio de configuración que — spoiler para el Ejercicio 5 — va a causar un incidente:

```bash
export GIT_AUTHOR_DATE="2026-07-08T10:00:00" GIT_COMMITTER_DATE="2026-07-08T10:00:00"
echo "pool=100" > config.txt
git add config.txt && git commit -m "feat: raise DB connection pool"
GIT_COMMITTER_DATE="2026-07-08T18:00:00" git tag -a v1.1.0 -m "deploy v1.1.0"
```

**4.** El hotfix que restaura el servicio, y un tercer release normal una semana después:

```bash
export GIT_AUTHOR_DATE="2026-07-08T19:30:00" GIT_COMMITTER_DATE="2026-07-08T19:30:00"
echo "pool=25" > config.txt
git add config.txt && git commit -m "fix: cap DB connection pool"
GIT_COMMITTER_DATE="2026-07-08T20:00:00" git tag -a v1.1.1 -m "hotfix v1.1.1"

export GIT_AUTHOR_DATE="2026-07-15T11:00:00" GIT_COMMITTER_DATE="2026-07-15T11:00:00"
echo "feature B" >> app.txt
git add app.txt && git commit -m "feat: order history"
GIT_COMMITTER_DATE="2026-07-15T13:00:00" git tag -a v1.2.0 -m "deploy v1.2.0"
```

**5.** **Deployment frequency**: listá los deploys por fecha:

```bash
git tag --sort=creatordate --format='%(creatordate:short) %(refname:short)'
```

Salida esperada:

```
2026-07-03 v1.0.0
2026-07-08 v1.1.0
2026-07-08 v1.1.1
2026-07-15 v1.2.0
```

Cuatro deploys en unas dos semanas: aproximadamente 2 por semana.

**6.** **Lead time for changes**: para cada deploy, el tiempo entre que el cambio entró a `main` (author date del commit) y llegó a producción (fecha del tag):

```bash
for tag in $(git tag --sort=creatordate); do
  commit_ts=$(git log -1 --format=%at "${tag}^{commit}")
  tag_ts=$(git for-each-ref --format='%(creatordate:unix)' "refs/tags/${tag}")
  echo "${tag}: lead time = $(( (tag_ts - commit_ts) / 3600 )) h"
done
```

Salida esperada:

```
v1.0.0: lead time = 54 h
v1.1.0: lead time = 8 h
v1.1.1: lead time = 0 h
v1.2.0: lead time = 2 h
```

(El hotfix tardó 30 minutos; la división entera lo redondea a 0.)

**7.** **Change failure rate y recovery time**: `v1.1.0` degradó producción y `v1.1.1` la restauró:

```bash
t_fail=$(git for-each-ref --format='%(creatordate:unix)' refs/tags/v1.1.0)
t_fix=$(git for-each-ref --format='%(creatordate:unix)' refs/tags/v1.1.1)
echo "CFR = 1 de 4 deploys = 25%"
echo "Recovery time = $(( (t_fix - t_fail) / 60 )) min"
```

Salida esperada:

```
CFR = 1 de 4 deploys = 25%
Recovery time = 120 min
```

### Preguntas

**1.1** Dos de las cuatro métricas miden *throughput* (velocidad) y dos miden *stability*. ¿Cuáles son cuáles, y por qué DORA insiste en medirlas juntas?

**1.2** Según los umbrales del *Accelerate State of DevOps Report* (https://dora.dev), ¿en qué banda de rendimiento cae este equipo en cada métrica? ¿Cuál mejorarías primero?

**1.3** ¿Por qué medimos el lead time desde el commit y no desde que se escribió la primera línea de código?

**1.4** En un contexto de platform engineering, ¿quién debería instrumentar estas métricas: cada equipo de producto, o la plataforma? ¿Por qué?

---

## Ejercicio 2 — Shift-left: mover la detección de errores del incidente al pre-commit

Un pilar de la cultura DevOps es acortar los *feedback loops*: cuanto antes se detecta un defecto, más barato es corregirlo. En este ejercicio validás manifiestos de Kubernetes contra su schema en tres puntos del ciclo — a mano, en un git hook local, y en CI — y comparás la latencia del feedback en cada uno.

**1.** Instalá `kubeconform` (validador de schema, https://github.com/yannh/kubeconform):

```bash
curl -sSL https://github.com/yannh/kubeconform/releases/latest/download/kubeconform-linux-amd64.tar.gz \
  | tar xz kubeconform
sudo mv kubeconform /usr/local/bin/
kubeconform -v
```

**2.** Creá un repositorio con un manifiesto que contiene un error real y frecuente — `replicas` como string:

```bash
mkdir shift-left-lab && cd shift-left-lab
git init -b main
git config user.email "student@example.com" && git config user.name "CNPA Student"
mkdir manifests
cat > manifests/deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-api
spec:
  replicas: "3"
  selector:
    matchLabels:
      app: payments-api
  template:
    metadata:
      labels:
        app: payments-api
    spec:
      containers:
        - name: api
          image: ghcr.io/example/payments-api:1.4.2
EOF
```

**3.** Feedback loop nº 1 — validación manual, latencia ~1 segundo:

```bash
kubeconform -summary -strict manifests/
```

Salida esperada:

```
manifests/deployment.yaml - Deployment payments-api is invalid: problem validating schema. Check JSON formatting: jsonschema: '/spec/replicas' does not validate with ...: expected integer or null, but got string
Summary: 1 resource found in 1 file - Valid: 0, Invalid: 1, Errors: 0, Skipped: 0
```

**4.** Feedback loop nº 2 — automatizado en un git hook, para que el error no pueda ni siquiera entrar al repositorio:

```bash
cat > .git/hooks/pre-commit <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
kubeconform -summary -strict manifests/
EOF
chmod +x .git/hooks/pre-commit

git add manifests/
git commit -m "feat: payments-api deployment"
```

El commit falla con la misma salida de kubeconform y exit code distinto de 0. Corregí `replicas: "3"` por `replicas: 3` y reintentá:

```bash
sed -i 's/replicas: "3"/replicas: 3/' manifests/deployment.yaml
git add manifests/ && git commit -m "feat: payments-api deployment"
```

Salida esperada:

```
Summary: 1 resource found in 1 file - Valid: 1, Invalid: 0, Errors: 0, Skipped: 0
[main (root-commit) a1b2c3d] feat: payments-api deployment
 1 file changed, 18 insertions(+)
```

**5.** Feedback loop nº 3 — la misma validación como *pipeline as code*, que la plataforma ofrece como template reutilizable a todos los equipos:

```bash
mkdir -p .github/workflows
cat > .github/workflows/validate.yaml <<'EOF'
name: validate-manifests
on: [pull_request]
jobs:
  kubeconform:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Validate Kubernetes manifests
        run: |
          curl -sSL https://github.com/yannh/kubeconform/releases/latest/download/kubeconform-linux-amd64.tar.gz | tar xz
          ./kubeconform -summary -strict manifests/
EOF
git add .github && git commit -m "ci: schema validation on every PR"
```

**6.** Anotá la latencia de feedback de cada punto de detección:

| Punto de detección | Latencia típica | Quién se entera |
|---|---|---|
| pre-commit hook | ~1 s | solo el autor |
| CI en el PR | 2–5 min | autor + reviewers |
| `kubectl apply` a prod | minutos–horas | on-call, y a veces el cliente |

### Preguntas

**2.1** El error `replicas: "3"` habría sido rechazado igualmente por el API server en el `kubectl apply`. ¿Por qué "shift left" sigue siendo valioso si el sistema ya lo iba a atajar al final?

**2.2** ¿Qué pilares del modelo CALMS (Culture, Automation, Lean, Measurement, Sharing) ejercitaste en los pasos 4 y 5?

**2.3** El hook de `.git/hooks/` no se versiona ni se comparte con el clone. ¿Cómo convertiría un platform team esta validación en un producto que todos los equipos consumen sin configurarla a mano?

**2.4** "You build it, you run it" a veces se implementa como "tirarle operaciones encima a los developers". ¿Qué diferencia hay entre eso y lo que hace un platform engineer con estos checks?

---

## Ejercicio 3 — Golden path: scaffolding de un servicio con las buenas prácticas incorporadas

El CNCF Platforms White Paper (https://tag-app-delivery.cncf.io/whitepapers/platforms/) define la plataforma como un producto que reduce la carga cognitiva de los equipos de producto mediante capacidades self-service. El artefacto más visible de esa idea es el *golden path*: un template que genera un servicio nuevo con Dockerfile, manifiestos y CI ya alineados con las políticas de la organización. Acá construís uno mínimo pero funcional.

**1.** Creá el template. Fijate que las buenas prácticas (probes, resources, `runAsNonRoot`) vienen incluidas — el developer las recibe "gratis", sin tener que conocerlas:

```bash
mkdir -p golden-path/template/k8s && cd golden-path

cat > template/Dockerfile <<'EOF'
FROM python:3.12-slim
WORKDIR /app
COPY . .
USER 65534
CMD ["python", "main.py"]
EOF

cat > template/k8s/deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: __SERVICE_NAME__
  labels:
    app.kubernetes.io/name: __SERVICE_NAME__
    app.kubernetes.io/managed-by: golden-path
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: __SERVICE_NAME__
  template:
    metadata:
      labels:
        app.kubernetes.io/name: __SERVICE_NAME__
    spec:
      securityContext:
        runAsNonRoot: true
      containers:
        - name: __SERVICE_NAME__
          image: registry.internal/__SERVICE_NAME__:latest
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits: { cpu: 500m, memory: 256Mi }
          readinessProbe:
            httpGet: { path: /healthz, port: 8080 }
          livenessProbe:
            httpGet: { path: /healthz, port: 8080 }
EOF

cat > template/README.md <<'EOF'
# __SERVICE_NAME__
Generated from the golden-path template. CI, deploy manifests and
security defaults are pre-wired; edit main.py and push.
EOF
```

**2.** Creá el generador — la versión de 20 líneas de lo que en producción sería Backstage Scaffolder o `cookiecutter`:

```bash
cat > new-service.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SERVICE="${1:?usage: new-service.sh <service-name>}"
DEST="services/${SERVICE}"
[ -e "${DEST}" ] && { echo "ERROR: ${DEST} already exists" >&2; exit 1; }
mkdir -p services
cp -r template "${DEST}"
grep -rl '__SERVICE_NAME__' "${DEST}" | xargs sed -i "s/__SERVICE_NAME__/${SERVICE}/g"
echo "Service ${SERVICE} scaffolded at ${DEST}"
EOF
chmod +x new-service.sh
```

**3.** Generá un servicio y verificá el resultado:

```bash
./new-service.sh billing-api
grep -r "billing-api" services/billing-api/k8s/deployment.yaml | head -3
```

Salida esperada:

```
Service billing-api scaffolded at services/billing-api
  name: billing-api
    app.kubernetes.io/name: billing-api
    app.kubernetes.io/managed-by: golden-path
```

**4.** Verificá la idempotencia del generador (una propiedad, no un accidente):

```bash
./new-service.sh billing-api
```

Salida esperada:

```
ERROR: services/billing-api already exists
```

**5.** Medí el valor: validá que el servicio generado ya pasa el gate del Ejercicio 2 sin que el developer haya escrito una sola línea de YAML:

```bash
kubeconform -summary -strict services/billing-api/k8s/
```

Salida esperada:

```
Summary: 1 resource found in 1 file - Valid: 1, Invalid: 0, Errors: 0, Skipped: 0
```

### Preguntas

**3.1** Team Topologies distingue carga cognitiva *intrinsic*, *extraneous* y *germane*. ¿Cuál de las tres reduce el golden path, y por qué es exactamente esa la que un platform team debe atacar?

**3.2** El white paper de CNCF insiste en que el uso de la plataforma sea **opcional**. ¿Qué riesgo cultural aparece si el golden path se vuelve obligatorio ("golden cage")?

**3.3** "Platform as a product" implica medir. Nombrá tres métricas concretas con las que evaluarías si este template es un buen producto.

**3.4** Seis meses después, el template cambia (por ejemplo, se agrega un `NetworkPolicy` por defecto). Los 40 servicios ya generados no lo tienen. ¿Qué estrategias existen para este problema de *day-2 drift*?

---

## Ejercicio 4 — GitOps como práctica DevOps: reconciliación continua y drift

GitOps es la materialización cloud native de dos pilares DevOps: automatización total del despliegue y Git como única fuente de verdad auditada. Acá instalás Argo CD en un cluster local, declarás una aplicación con `selfHeal`, y comprobás que el sistema revierte solo los cambios manuales — el fin del `kubectl edit` en producción.

**1.** Creá el cluster e instalá Argo CD:

```bash
kind create cluster --name cnpa-devops
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd wait --for=condition=Available deploy --all --timeout=300s
```

Salida esperada (última línea de cada wait):

```
deployment.apps/argocd-server condition met
```

**2.** Declarás la aplicación de forma **declarativa** — un manifiesto `Application`, no un click ni un comando imperativo:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: guestbook
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/argoproj/argocd-example-apps.git
    targetRevision: HEAD
    path: guestbook
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF
```

**3.** Esperá la sincronización y verificá el estado:

```bash
sleep 30
kubectl -n argocd get application guestbook
kubectl -n default get deployment guestbook-ui
```

Salida esperada:

```
NAME        SYNC STATUS   HEALTH STATUS
guestbook   Synced        Healthy

NAME           READY   UP-TO-DATE   AVAILABLE   AGE
guestbook-ui   1/1     1            1           45s
```

**4.** Provocá **drift** imperativo — lo que en un modelo pre-DevOps sería "un cambio rápido en prod" — y observá en vivo cómo el reconciler lo revierte:

```bash
kubectl -n default scale deployment guestbook-ui --replicas=5
kubectl -n default get deployment guestbook-ui -w
```

Salida esperada (interrumpí con `Ctrl-C` cuando vuelva a 1):

```
NAME           READY   UP-TO-DATE   AVAILABLE   AGE
guestbook-ui   1/5     5            1           2m
guestbook-ui   1/1     1            1           2m4s
```

El cluster volvió al estado declarado en Git en segundos, sin intervención humana.

**5.** Caso extremo: borrá el Deployment entero y verificá que reaparece:

```bash
kubectl -n default delete deployment guestbook-ui
sleep 10
kubectl -n default get deployment guestbook-ui
```

Salida esperada:

```
NAME           READY   UP-TO-DATE   AVAILABLE   AGE
guestbook-ui   1/1     1            1           8s
```

Fijate en `AGE`: es un objeto nuevo, recreado por el reconciler.

**6.** Limpieza:

```bash
kind delete cluster --name cnpa-devops
```

### Preguntas

**4.1** Enumerá los cuatro principios de OpenGitOps (https://opengitops.dev) e indicá en qué paso de este ejercicio observaste cada uno.

**4.2** ¿Qué diferencia operacional hay entre el modelo *push* (el pipeline de CI ejecuta `kubectl apply`) y el modelo *pull* que acabás de usar? Mencioná al menos una ventaja de seguridad del pull.

**4.3** Con `selfHeal: true`, ¿cuál pasa a ser el **único** mecanismo legítimo de cambio en producción, y qué práctica cultural DevOps convierte eso en una ventaja (pista: ¿dónde se discuten ahora los cambios?)?

**4.4** ¿Qué DORA metric del Ejercicio 1 mejora más directamente con la reconciliación automática, y por qué?

---

## Ejercicio 5 — Blameless postmortem del incidente v1.1.0

Volvé al incidente que simulaste en el Ejercicio 1: `v1.1.0` subió el pool de conexiones a la base de datos de 10 a 100, agotó los slots del servidor PostgreSQL compartido y tiró el servicio de pagos durante casi dos horas. La cultura DevOps exige convertir ese incidente en aprendizaje organizacional, no en un culpable. La referencia canónica es el capítulo "Postmortem Culture" del libro de SRE de Google (https://sre.google/sre-book/postmortem-culture/).

**1.** Estos son los hechos crudos del incidente:

- `17:55` — merge del PR "raise DB connection pool" (revisado y aprobado por un colega).
- `18:00` — deploy de `v1.1.0` directo al 100% del tráfico; no existe canary.
- `18:15` — alerta `PGConnectionsSaturated` dispara; el on-call la recibe.
- `18:20–19:10` — el on-call investiga la base de datos; no sabe que hubo un deploy porque las notificaciones de deploy van a otro canal.
- `19:10` — un developer menciona el deploy en el canal del incidente; se correlaciona.
- `19:30` — commit del fix (`pool=25`); no hay procedimiento documentado de rollback rápido.
- `20:00` — deploy de `v1.1.1`; el servicio se recupera.

**2.** Creá el archivo `postmortem-v1.1.0.md` con esta plantilla y completala vos (no mires todavía las respuestas):

```markdown
# Postmortem: payments outage 2026-07-08 (v1.1.0)

## Impact
<duración, servicios afectados, usuarios afectados>

## Timeline
<pegá los hechos, hora por hora>

## Contributing factors
<mínimo tres factores SISTÉMICOS; prohibido "human error">

## What went well
<mínimo uno>

## Action items
| Action | Type (prevent/detect/mitigate) | Owner | Priority |
|---|---|---|---|
```

**3.** Regla de redacción obligatoria: cada *contributing factor* debe describir una condición del **sistema** que permitió el fallo, no una decisión de una persona. Test rápido: si la frase sigue teniendo sentido reemplazando el nombre de la persona por "cualquier ingeniero razonable", es sistémica; si no, reescribila.

**4.** Calculá el desglose del recovery time y anotalo en el postmortem: ¿cuánto tiempo se fue en **detectar** (18:00→18:15), cuánto en **diagnosticar** (18:15→19:10) y cuánto en **remediar** (19:10→20:00)? Ese desglose te dice qué action item comprime más el MTTR.

### Preguntas

**5.1** ¿Por qué la condición *blameless* no es solo amabilidad sino un requisito **funcional** para que el postmortem produzca información veraz?

**5.2** "El root cause fue que el ingeniero subió el pool sin calcular la capacidad de la base." Señalá los dos errores conceptuales de esa frase.

**5.3** De tu desglose del paso 4, ¿qué fase dominó el recovery time y qué action item concreto la ataca?

**5.4** ¿Qué action item de este incidente le corresponde implementar al **platform team** y no al equipo de pagos? ¿Por qué esa asignación importa culturalmente?

---

## Ejercicio 6 — Team Topologies: clasificar equipos e interacciones

El modelo de Team Topologies (https://teamtopologies.com/key-concepts) es el vocabulario que el curriculum del CNPA usa para ubicar al platform team dentro de la organización: cuatro tipos de equipo (*stream-aligned*, *platform*, *enabling*, *complicated-subsystem*) y tres modos de interacción (*collaboration*, *X-as-a-Service*, *facilitating*).

**1.** Leé los cuatro escenarios y clasificá cada equipo por tipo:

- **(a)** Equipo dueño del servicio de checkout de punta a punta: lo desarrolla, lo despliega y hace la guardia.
- **(b)** Equipo que mantiene el portal interno donde cualquier equipo crea un servicio nuevo (el golden path del Ejercicio 3), pide una base de datos o consulta sus dashboards, todo self-service.
- **(c)** Equipo de tres personas que rota por los equipos de producto durante un trimestre cada uno, enseñándoles a instrumentar sus servicios con OpenTelemetry, y después se va.
- **(d)** Equipo que mantiene el motor de detección de fraude basado en ML, que requiere conocimiento estadístico que ningún otro equipo tiene.

**2.** Clasificá ahora el **modo de interacción** de cada situación:

- **(i)** Un equipo de producto consume la API del portal interno sin hablar con nadie.
- **(ii)** El platform team se sienta dos sprints con el primer equipo que va a usar la nueva capacidad de bases de datos gestionadas, para descubrir juntos la interfaz correcta.
- **(iii)** El equipo del escenario (c) haciendo pairing sobre instrumentación.

**3.** Dibujá (en papel o texto) la relación entre los equipos (a) y (b) hoy, y cómo debería evolucionar el modo de interacción de (ii) con el tiempo.

### Preguntas

**6.1** Confirmá tu clasificación de tipos y modos (respuestas abajo). ¿Qué modo de interacción debe **dominar** la relación estable entre un platform team y los stream-aligned teams, y por qué los otros dos modos deben ser transitorios o excepcionales?

**6.2** ¿Qué señal cultural negativa indica que un platform team está operando en modo *collaboration* permanente con todos los equipos a la vez?

**6.3** ¿Por qué el equipo (c) **no** es un platform team, aunque "ayuda a todos los equipos"? ¿Qué entrega uno y qué entrega el otro?

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1

**1.1** *Throughput*: deployment frequency y lead time for changes. *Stability*: change failure rate y failed deployment recovery time. Se miden juntas porque cada par es el contrapeso del otro: optimizar solo velocidad degrada estabilidad y viceversa. El hallazgo central de DORA (https://dora.dev/guides/dora-metrics-four-keys/) es que los equipos de élite mejoran las cuatro a la vez — velocidad y estabilidad no son un trade-off sino co-productos de las mismas prácticas (lotes chicos, automatización, feedback rápido).

**1.2** Deployment frequency ~2/semana → banda **High** (entre una vez por semana y una vez por día). Lead time: mediana bajo un día → **High/Elite**, aunque las 54 h de v1.0.0 muestran varianza alta. CFR 25% → por encima del ~5–15% de las bandas altas del reporte 2023 → **Medium/Low**. Recovery de 2 h → menos de un día → **High** (Elite es < 1 h). Primero atacaría el CFR: un 25% de deploys fallidos indica ausencia de validación progresiva (canary, feature flags), y eso además frena la frecuencia porque cada deploy da miedo.

**1.3** Porque el lead time DORA mide la eficiencia del **sistema de entrega** (integración, testing, aprobaciones, deploy), que es lo que la organización controla y puede automatizar. El tiempo de desarrollo previo al commit varía con la complejidad del problema y no distingue un pipeline sano de uno enfermo.

**1.4** La plataforma. Si cada equipo lo instrumenta a su manera, las métricas no son comparables ni confiables, y el costo se paga N veces. Un platform team que ya es dueño del pipeline de CI/CD puede emitir las cuatro métricas como subproducto automático de cada deploy — es el pilar *Measurement* de CALMS ofrecido as-a-Service. La advertencia cultural: son métricas para mejorar el sistema, no para rankear equipos; usarlas como arma gerencial destruye la honestidad de los datos.

### Ejercicio 2

**2.1** Porque el costo del defecto crece en órdenes de magnitud con cada etapa: en el pre-commit lo arregla el autor en segundos con todo el contexto en la cabeza; en el `kubectl apply` de un deploy real ya interrumpió a un pipeline completo, quizás a un on-call, y bloqueó el release de los cambios que viajaban junto al suyo. Además el API server solo valida schema; el mismo mecanismo de shift-left permite mover a la izquierda validaciones que el API server **no** hace (policies, seguridad, convenciones internas).

**2.2** *Automation*: la validación corre sin intervención humana en el hook y en el pipeline. *Lean*: el feedback loop se acorta de horas a segundos, eliminando desperdicio (trabajo en lote defectuoso que avanza). Indirectamente *Sharing*: el workflow de CI versionado en el repo es conocimiento operativo compartido y reutilizable, no tribal.

**2.3** Sacándola del `.git/hooks/` local (que no viaja con el clone) y empaquetándola como producto: un template de CI reutilizable y versionado (por ejemplo un *reusable workflow* de GitHub Actions o un include de GitLab CI mantenido por la plataforma), incluido por defecto en el golden path del Ejercicio 3, más una configuración de framework tipo `pre-commit` distribuida en el template. Los equipos lo consumen sin configurarlo y reciben las mejoras centralizadamente.

**2.4** La versión tóxica transfiere la **carga** (ahora los developers hacen ops a mano, además de desarrollar). El platform engineering transfiere la **responsabilidad** pero absorbe la carga en la plataforma: el equipo de producto sigue siendo dueño del resultado en producción, pero opera mediante capacidades self-service (checks automáticos, pipelines, observabilidad pre-cableada) que hacen que ejercer esa responsabilidad no requiera expertise de infraestructura. Es la diferencia entre delegar trabajo y reducir carga cognitiva (CNCF Platforms White Paper).

### Ejercicio 3

**3.1** La **extraneous** (extrínseca): todo el conocimiento que no aporta al problema de negocio — sintaxis de Deployment, qué probes poner, qué labels exige la organización, cómo se estructura el CI. La *intrinsic* (saber programar) no es transferible, y la *germane* (el dominio de negocio: pagos, checkout) es exactamente donde el equipo **debe** gastar su capacidad cognitiva. El golden path elimina la extrínseca para maximizar el presupuesto disponible para la germane.

**3.2** Si es obligatorio y rígido, la plataforma deja de comportarse como producto y se convierte en un gate de aprobación con otro nombre: los equipos que tienen un caso de uso legítimo fuera del template lo esquivan por canales grises (shadow IT), dejan de dar feedback, y la plataforma pierde la señal de mercado interna que la mantiene útil. La opcionalidad obliga a la plataforma a ganarse la adopción por valor — que es el mecanismo cultural que la mantiene buena.

**3.3** Ejemplos válidos: (1) *adoption rate* — % de servicios nuevos creados vía template vs a mano; (2) *time to first deploy* — tiempo desde "necesito un servicio" hasta la primera versión corriendo; (3) satisfacción del developer (encuestas internas tipo NPS/DevEx); también sirven: % de servicios que pasan los policy checks al primer intento, tickets de soporte por servicio generado.

**3.4** Opciones reales: (1) PRs automatizados que propagan cambios del template a los repos derivados (el patrón de herramientas como Backstage + bots de actualización, o `cruft` sobre cookiecutter); (2) mover la lógica compartida **fuera** del código generado hacia referencias versionadas (imágenes base, Helm charts, reusable workflows), de modo que el template genere poco y referencie mucho; (3) *conformance checks* en CI que detectan servicios desviados del baseline y abren issues. Lo que no funciona es el memo pidiendo que cada equipo se actualice a mano.

### Ejercicio 4

**4.1** (1) **Declarative**: el estado deseado se expresa como datos — el manifiesto `Application` del paso 2 y los manifiestos del repo guestbook. (2) **Versioned and immutable**: la fuente de verdad es un repo Git con historial — `repoURL`/`targetRevision` del paso 2. (3) **Pulled automatically**: Argo CD extrae el estado deseado desde dentro del cluster sin que nadie ejecute un push — la sincronización sola del paso 3. (4) **Continuously reconciled**: los pasos 4 y 5, donde el drift (scale manual, delete) se corrige sin intervención.

**4.2** En push, el sistema de CI tiene credenciales de administrador del cluster y el estado real solo cambia cuando corre un pipeline; entre corridas, el drift es invisible. En pull, el agente corre dentro del cluster y solo necesita acceso de **lectura** al repo: las credenciales del cluster nunca salen de él, la superficie de ataque del CI se reduce drásticamente, y la reconciliación es continua, no episódica. Además el pull da un plano de auditoría uniforme: el estado del cluster siempre es explicable por un commit.

**4.3** El único mecanismo legítimo pasa a ser el **pull request al repositorio de configuración**. La práctica cultural que lo convierte en ventaja es el code review + trazabilidad: cada cambio de producción queda discutido, aprobado y atribuido en el historial de Git — el change management deja de ser un comité y pasa a ser el flujo normal de trabajo del developer. `kubectl edit` en prod deja de existir no por prohibición sino porque sus efectos se revierten solos.

**4.4** **Failed deployment recovery time** (MTTR). Con Git como fuente de verdad, restaurar el servicio es `git revert` + sincronización automática: un camino de vuelta ensayado, de minutos, idéntico al camino de ida. En el incidente del Ejercicio 5, gran parte de los 120 minutos se fueron precisamente por no tener un procedimiento de rollback — con GitOps ese procedimiento es el sistema mismo. (Argumento secundario válido: también baja el CFR, porque elimina la clase entera de fallos por drift y cambios manuales no auditados.)

### Ejercicio 5

**5.1** Porque el insumo del postmortem es información que **solo tienen los involucrados**: qué vieron, qué asumieron, qué sabían y qué no en cada momento. Si contar la verdad tiene costo personal (sanción, vergüenza, quedar marcado), la información se retira o se edita, y el análisis se hace sobre datos falsos. Blameless no es perdonar: es diseñar el incentivo para que la información fluya completa, que es la única forma de arreglar el sistema.

**5.2** Primero, presupone un **root cause único**, cuando el incidente necesitó varias condiciones simultáneas: sin canary, alertas de deploy en otro canal, sin runbook de rollback, sin límite de conexiones a nivel plataforma — sacá cualquiera y el impacto cambia radicalmente. Segundo, se detiene en el **humano** como causa: "el ingeniero no calculó" no es accionable (el PR además fue aprobado por otra persona — dos ingenieros razonables no lo vieron, lo que prueba que el sistema no hacía visible la capacidad de la base). El factor sistémico accionable es "un cambio de configuración con impacto en capacidad compartida puede llegar al 100% del tráfico sin validación progresiva".

**5.3** Detección: 15 min. Diagnóstico: 55 min. Remediación: 50 min. Dominó el **diagnóstico**, y dentro de él, los 50 minutos perdidos por no correlacionar la alerta con el deploy. Action item concreto: anotar automáticamente cada deploy como evento en el sistema de observabilidad y en el canal de on-call (deploy markers), de modo que la primera pregunta del diagnóstico — "¿qué cambió?" — se responda en segundos. El segundo item en impacto es el runbook/mecanismo de rollback, que ataca los 50 min de remediación.

**5.4** Los mecanismos transversales: canary/progressive delivery como capacidad del pipeline, deploy markers en observabilidad, y el procedimiento de rollback estándar (idealmente GitOps, Ejercicio 4). Culturalmente importa porque si cada action item cae en el equipo de pagos, el aprendizaje queda local y el resto de la organización repetirá el mismo incidente; cuando la plataforma absorbe el fix, el aprendizaje de **un** incidente se convierte en protección para **todos** los equipos — eso es el pilar *Sharing* de CALMS hecho infraestructura.

### Ejercicio 6

**6.1** Tipos: (a) **stream-aligned**, (b) **platform**, (c) **enabling**, (d) **complicated-subsystem**. Modos: (i) **X-as-a-Service**, (ii) **collaboration**, (iii) **facilitating**. El modo dominante en régimen estable debe ser **X-as-a-Service**: es el único que escala (la plataforma atiende a N equipos sin que su carga crezca linealmente con N) y el único que minimiza la carga cognitiva de ambos lados mediante una interfaz clara. *Collaboration* es caro en atención y debe reservarse para el descubrimiento de capacidades nuevas; *facilitating* es por definición temporal — si no termina, no enseñó.

**6.2** Que la plataforma se volvió un cuello de botella de personas en lugar de un producto: cada equipo necesita "hablar con alguien de plataforma" para avanzar, los tickets crecen, y el throughput de toda la organización queda limitado por el calendario del platform team. Es la señal de que falta interfaz self-service — la capacidad existe, pero como servicio artesanal, no como producto.

**6.3** El equipo (c) entrega **capacidad en las personas** (aprenden a instrumentar y quedan autónomos; el equipo enabling se retira). Un platform team entrega **capacidad en el sistema** (una plataforma operada como producto, con la que los equipos interactúan de forma permanente vía self-service). Son complementarios: el enabling team reduce la brecha de conocimiento para adoptar lo que la plataforma ofrece; confundirlos lleva o a plataformas sin adopción o a "consultores internos" eternos que nunca escalan.

</details>

---

## Fuentes

- CNCF — CNPA Curriculum: https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- CNCF TAG App Delivery — Platforms White Paper: https://tag-app-delivery.cncf.io/whitepapers/platforms/
- CNCF TAG App Delivery — Platform Engineering Maturity Model: https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/
- DORA — The Four Keys / State of DevOps: https://dora.dev/guides/dora-metrics-four-keys/
- OpenGitOps — GitOps Principles v1.0.0: https://opengitops.dev/
- Argo CD — Documentación oficial: https://argo-cd.readthedocs.io/en/stable/
- Google — SRE Book, "Postmortem Culture": https://sre.google/sre-book/postmortem-culture/
- Team Topologies — Key Concepts: https://teamtopologies.com/key-concepts
- kubeconform: https://github.com/yannh/kubeconform