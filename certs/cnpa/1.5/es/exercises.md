# Ejercicios guiados — CNPA 1.5

## Platform Engineering Goals, Objectives, and Strategic Approaches

> **Peso en el examen: 7.2 %** · Dominio *Platform Engineering Core Fundamentals*
> Estos ejercicios son de laboratorio: se ejecutan de arriba a abajo, en orden, sobre un cluster desechable. Cada bloque termina con preguntas de verificación; las respuestas están al final, en la sección colapsable.

---

## 0. Preparación del entorno

Todo el laboratorio se hace en un directorio único. Vas a construir, sobre él, una plataforma mínima real (chart, SLOs, RBAC, métricas, ADRs) que después usás como evidencia de cada concepto del temario.

### Herramientas requeridas

| Herramienta | Versión mínima | Uso en el lab |
|---|---|---|
| `kubectl` | 1.30 | ejercicios 1, 3, 7 |
| `kind` | 0.23 | cluster desechable |
| `helm` | 3.14 | golden path (ej. 3) |
| `yq` | 4.x | manipulación de YAML |
| `jq` | 1.6 | parseo de salidas |
| `git` | 2.40 | métricas DORA (ej. 4) |
| `python3` + `pyyaml` | 3.11 | scripts de scoring (ej. 4, 5, 6) |
| `promtool` | 2.50 | validación de reglas SLO (ej. 4) |

```bash
mkdir -p ~/cnpa-1.5 && cd ~/cnpa-1.5
python3 -m venv .venv && ./.venv/bin/pip install -q pyyaml
git init -q -b main
```

Cluster:

```bash
cat > kind.yaml <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: cnpa-platform
nodes:
  - role: control-plane
  - role: worker
  - role: worker
EOF

kind create cluster --config kind.yaml
kubectl cluster-info --context kind-cnpa-platform
```

Salida esperada (abreviada):

```
Kubernetes control plane is running at https://127.0.0.1:34211
CoreDNS is running at https://127.0.0.1:34211/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy
```

---

## Ejercicio 1 — Medir la línea base: carga cognitiva antes de la plataforma

**Objetivo del ejercicio.** El primer objetivo declarado del platform engineering según el [CNCF Platforms White Paper](https://tag-app-delivery.cncf.io/whitepapers/platforms/) es *reducir la carga cognitiva extrínseca* del equipo de producto. "Reducir" es un verbo comparativo: sin línea base no hay objetivo, hay eslogan. Este ejercicio produce el número **antes**.

### Bloque 1.A — Cuantificar la superficie de API que un developer debe conocer

1. Contá el tamaño del contrato que un developer enfrenta si escribe manifiestos a mano:

```bash
kubectl explain deployment --recursive | wc -l
kubectl explain deployment.spec.template.spec.containers --recursive | wc -l
kubectl explain networkpolicy --recursive | wc -l
```

Salida esperada (los valores exactos dependen de la versión del API server):

```
1147
 812
  96
```

2. Contá cuántos *kinds* distintos participan del despliegue mínimo de un servicio HTTP en producción:

```bash
cat > baseline/kinds.txt <<'EOF'
Deployment
Service
Ingress
ServiceAccount
HorizontalPodAutoscaler
PodDisruptionBudget
NetworkPolicy
ConfigMap
EOF
mkdir -p baseline && wc -l < baseline/kinds.txt
```

3. Escribí a mano el manifiesto "artesanal" que hoy copia-pega cada equipo, y medilo:

```bash
mkdir -p baseline/checkout
# (usá tu propio manifiesto real de producción si lo tenés;
#  si no, generá el equivalente al final del ejercicio 3 y volvé acá)
find baseline/checkout -name '*.yaml' | xargs cat | grep -vc '^\s*#\|^\s*$'
```

Salida de referencia en el lab:

```
214
```

4. Calculá el **índice de carga cognitiva de onboarding** con la fórmula operativa que vas a usar como SLI en el ejercicio 4:

```bash
python3 - <<'EOF'
kinds      = 8      # kinds que el dev debe conocer
fields     = 214    # líneas de YAML que debe escribir/mantener
decisions  = 23     # decisiones sin default seguro (límites, probes, políticas...)
print(f"cognitive load index (baseline) = {kinds * decisions + fields}")
EOF
```

```
cognitive load index (baseline) = 398
```

> El valor absoluto no significa nada. Lo único que importa es que el **mismo** cálculo, repetido después del ejercicio 3, dé un número más chico. Un objetivo de plataforma es una *delta*, no un absoluto.

### Preguntas de verificación — bloque 1

**P1.1** ¿Por qué "reducir la carga cognitiva" no es, por sí solo, un objetivo válido de plataforma en el sentido del CNCF Platform Engineering Maturity Model?

**P1.2** Team Topologies distingue carga cognitiva *intrínseca*, *extrínseca* (extraneous) y *pertinente* (germane). ¿Cuál de las tres ataca legítimamente una plataforma, y qué pasa si intenta eliminar las otras dos?

**P1.3** Un equipo propone bajar el índice a 0 prohibiendo que los developers vean YAML: todo se pide por ticket al platform team. ¿Reduce la carga cognitiva? ¿Qué anti-pattern del temario introduce?

**P1.4** ¿Por qué medir `kubectl explain --recursive | wc -l` es una proxy pobre de carga cognitiva, y qué medición la reemplazaría en producción?

---

## Ejercicio 2 — La plataforma como producto: charter, personas y contrato

**Objetivo del ejercicio.** "Platform as a product" es el enfoque estratégico central del tema 1.5. Su artefacto verificable no es una wiki: es un **charter** con usuarios nombrados, un problema acotado, objetivos medibles y un *non-goals* explícito. Sin non-goals, la plataforma crece hasta volverse un sistema operativo interno que nadie mantiene.

### Bloque 2.A — Escribir el charter

1. Creá la estructura de producto:

```bash
mkdir -p platform/product platform/docs
```

2. Escribí el charter. Notá que cada objetivo tiene **métrica, línea base y meta con fecha**:

```bash
cat > platform/product/charter.md <<'EOF'
# Platform Product Charter — Internal Developer Platform "acme-idp"

## 1. Problem statement
Un equipo de producto tarda hoy 9 días hábiles desde que empieza un servicio HTTP
nuevo hasta que sirve tráfico en producción. El 71 % de ese tiempo se va en
esperar tickets de infra (namespace, DNS, TLS, pipeline) y en depurar YAML copiado
de otro repositorio.

## 2. Users (personas)
- **Dana, Product Developer.** Escribe Go y TypeScript. No sabe (ni quiere saber)
  qué es un PodDisruptionBudget. Éxito = su commit llega a producción hoy.
- **Raj, Tech Lead de stream-aligned team.** Rinde cuentas por el SLO del servicio.
  Éxito = puede explicar una caída sin abrir un ticket a infra.
- **Nadia, SRE de la plataforma.** Éxito = una sola forma de desplegar, no 40.
- **Cris, Security Engineer.** Éxito = las políticas se cumplen por construcción,
  no por auditoría posterior.

NO son usuarios de esta plataforma: los equipos de data engineering (usan Airflow
gestionado por otro grupo) y los servicios legacy en VMs.

## 3. Objectives (con métrica, baseline y meta)
| # | Objetivo | SLI | Baseline (2026-08-01) | Meta | Fecha |
|---|---|---|---|---|---|
| O1 | Bajar el time-to-first-deploy | p50 de horas commit→prod de un servicio nuevo | 9 d | < 4 h | 2026-11-30 |
| O2 | Aumentar la adopción del golden path | % de servicios productivos desplegados por el golden path | 0 % | > 60 % | 2026-11-30 |
| O3 | Reducir carga cognitiva | líneas de YAML mantenidas por servicio | 214 | < 15 | 2026-10-31 |
| O4 | Sostener la confiabilidad de la plataforma | disponibilidad del control plane de la plataforma | s/d | 99.5 % mensual | continuo |

## 4. Non-goals (explícitos, revisables cada trimestre)
- NO soportamos workloads con estado en esta versión (bases de datos: servicio
  gestionado del cloud provider).
- NO somos el único camino permitido: quien necesite salir del golden path puede
  hacerlo declarando el motivo; la plataforma no bloquea, expone el costo.
- NO reemplazamos al equipo de seguridad; implementamos sus políticas como código.

## 5. Interfaces del producto
CLI (`acme`), API declarativa (CRDs), portal web, plantillas de scaffolding y
documentación versionada. Toda interfaz tiene versión y política de deprecación
de 2 releases (~90 días).

## 6. Funding & staffing model
Producto financiado como centro de producto con presupuesto propio y 5 FTE, no
como costo prorrateado por proyecto. Sin roadmap propio no hay producto.

## 7. Feedback loop
- Entrevistas: 3 por mes con personas distintas.
- Encuesta DX trimestral (escala 1–5, pregunta central: "¿recomendarías la
  plataforma a otro equipo?").
- Canal `#platform-help` con etiquetado de fricción; cada tema recurrente entra
  al backlog como item, no como respuesta puntual.
EOF
```

3. Validá el charter con una prueba automática. La regla: **un objetivo sin unidad ni fecha no es un objetivo**.

```bash
cat > platform/product/validate_charter.py <<'PY'
#!/usr/bin/env python3
"""Fail if the charter states objectives without metric, baseline and deadline."""
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()

required = ["## 1. Problem statement", "## 2. Users", "## 3. Objectives",
            "## 4. Non-goals", "## 7. Feedback loop"]
missing = [s for s in required if s not in text]
if missing:
    sys.exit(f"charter is missing mandatory sections: {missing}")

rows = [r for r in text.splitlines() if re.match(r"^\|\s*O\d+\s*\|", r)]
if not rows:
    sys.exit("no objectives found: a charter without objectives is a manifesto")

bad = [r for r in rows if not re.search(r"\d{4}-\d{2}-\d{2}|continuo", r)]
if bad:
    sys.exit(f"{len(bad)} objective(s) without a deadline:\n" + "\n".join(bad))

print(f"OK: {len(rows)} objectives, all with metric and deadline")
PY
python3 platform/product/validate_charter.py platform/product/charter.md
```

```
OK: 4 objectives, all with metric and deadline
```

4. Rompé el charter a propósito para ver la prueba fallar (una prueba que nunca falló no es una prueba):

```bash
sed -i 's/| 2026-11-30 |/| pronto |/' platform/product/charter.md
python3 platform/product/validate_charter.py platform/product/charter.md; echo "exit=$?"
git checkout -- platform/product/charter.md 2>/dev/null || sed -i 's/| pronto |/| 2026-11-30 |/' platform/product/charter.md
```

```
1 objective(s) without a deadline:
| O1 | Bajar el time-to-first-deploy | p50 de horas commit→prod de un servicio nuevo | 9 d | < 4 h | pronto |
exit=1
```

### Preguntas de verificación — bloque 2

**P2.1** El charter declara explícitamente que la plataforma **no** es el único camino permitido. ¿Qué principio estratégico del temario expresa esa línea, y por qué una plataforma obligatoria degrada la señal de calidad del producto?

**P2.2** ¿Por qué la sección *non-goals* es tan importante como la de objetivos? Dé un ejemplo de qué falla cuando se omite.

**P2.3** El modelo de financiamiento aparece en un charter técnico. ¿Qué relación tiene el funding model con la madurez de la plataforma según el aspecto *Investment* del CNCF Platform Engineering Maturity Model?

**P2.4** O2 mide "% de servicios desplegados por el golden path". ¿Es un indicador *leading* o *lagging* respecto de O1? ¿Por qué la adopción es la métrica que más rápido detecta un producto equivocado?

**P2.5** Dana declara que no quiere saber qué es un PodDisruptionBudget. ¿Significa eso que su servicio no debe tener uno? ¿Quién decide el valor y dónde vive esa decisión?

---

## Ejercicio 3 — Thinnest Viable Platform: construir un golden path y medir su leverage

**Objetivo del ejercicio.** El *Thinnest Viable Platform* (TVP) es la respuesta estratégica a "¿por dónde empiezo?": la mínima cosa que resuelve el camino más transitado, y nada más. Acá lo construís como un golden path ejecutable y medís la **razón de apalancamiento**: líneas que el developer escribe versus líneas que la plataforma genera y mantiene por él.

### Bloque 3.A — Construir el golden path

1. Estructura del chart:

```bash
mkdir -p platform/golden-paths/http-service/templates
```

2. Metadatos y contrato del chart:

```bash
cat > platform/golden-paths/http-service/Chart.yaml <<'EOF'
apiVersion: v2
name: http-service
description: Golden path for stateless HTTP services on acme-idp
type: application
version: 0.1.0
appVersion: "0.1.0"
annotations:
  platform.acme.io/owner: platform-team
  platform.acme.io/support: "#platform-help"
EOF
```

3. Los defaults opinados. Éste es el corazón del TVP: **la plataforma decide todo lo que no diferencia al producto**.

```bash
cat > platform/golden-paths/http-service/values.yaml <<'EOF'
# --- developer-facing (los únicos campos que un usuario toca) ---
name: ""
image: ""
port: 8080
env: {}

# --- platform-owned defaults (versionados, cambiables por el platform team) ---
replicas: 2
probes:
  readinessPath: /healthz
  livenessPath: /healthz
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    memory: 256Mi
autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 10
  targetCPUUtilizationPercentage: 70
networkPolicy:
  enabled: true
  ingressFromNamespace: ingress-nginx
EOF
```

4. El *schema* del contrato. Que la interfaz sea un contrato verificable, y no un YAML de buena fe, es lo que separa una plataforma de un directorio de plantillas:

```bash
cat > platform/golden-paths/http-service/values.schema.json <<'EOF'
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["name", "image"],
  "properties": {
    "name":  { "type": "string", "pattern": "^[a-z]([-a-z0-9]*[a-z0-9])?$", "maxLength": 40 },
    "image": { "type": "string", "pattern": "^[^:]+:[^:]+$" },
    "port":  { "type": "integer", "minimum": 1024, "maximum": 65535 },
    "env":   { "type": "object", "additionalProperties": { "type": "string" } }
  }
}
EOF
```

5. Helpers y templates:

```bash
cat > platform/golden-paths/http-service/templates/_helpers.tpl <<'EOF'
{{- define "http-service.name" -}}
{{- .Values.name | default .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "http-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "http-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "http-service.labels" -}}
{{ include "http-service.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: acme-idp
platform.acme.io/golden-path: http-service
platform.acme.io/golden-path-version: {{ .Chart.Version | quote }}
{{- end -}}
EOF
```

```bash
cat > platform/golden-paths/http-service/templates/deployment.yaml <<'EOF'
{{- $name := include "http-service.name" . -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ $name }}
  labels:
    {{- include "http-service.labels" . | nindent 4 }}
spec:
  {{- if not .Values.autoscaling.enabled }}
  replicas: {{ .Values.replicas }}
  {{- end }}
  revisionHistoryLimit: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  selector:
    matchLabels:
      {{- include "http-service.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "http-service.labels" . | nindent 8 }}
    spec:
      serviceAccountName: {{ $name }}
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              {{- include "http-service.selectorLabels" . | nindent 14 }}
      containers:
        - name: app
          image: {{ required "el golden path exige el campo 'image'" .Values.image | quote }}
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: {{ .Values.port }}
          {{- with .Values.env }}
          env:
            {{- range $k, $v := . }}
            - name: {{ $k }}
              value: {{ $v | quote }}
            {{- end }}
          {{- end }}
          readinessProbe:
            httpGet:
              path: {{ .Values.probes.readinessPath }}
              port: http
            periodSeconds: 5
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: {{ .Values.probes.livenessPath }}
              port: http
            periodSeconds: 10
            failureThreshold: 6
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
EOF
```

```bash
cat > platform/golden-paths/http-service/templates/service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: {{ include "http-service.name" . }}
  labels:
    {{- include "http-service.labels" . | nindent 4 }}
spec:
  type: ClusterIP
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
  selector:
    {{- include "http-service.selectorLabels" . | nindent 4 }}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "http-service.name" . }}
  labels:
    {{- include "http-service.labels" . | nindent 4 }}
automountServiceAccountToken: false
EOF
```

```bash
cat > platform/golden-paths/http-service/templates/scaling.yaml <<'EOF'
{{- if .Values.autoscaling.enabled }}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ include "http-service.name" . }}
  labels:
    {{- include "http-service.labels" . | nindent 4 }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ include "http-service.name" . }}
  minReplicas: {{ .Values.autoscaling.minReplicas }}
  maxReplicas: {{ .Values.autoscaling.maxReplicas }}
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ .Values.autoscaling.targetCPUUtilizationPercentage }}
{{- end }}
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ include "http-service.name" . }}
  labels:
    {{- include "http-service.labels" . | nindent 4 }}
spec:
  minAvailable: 1
  selector:
    matchLabels:
      {{- include "http-service.selectorLabels" . | nindent 6 }}
EOF
```

```bash
cat > platform/golden-paths/http-service/templates/networkpolicy.yaml <<'EOF'
{{- if .Values.networkPolicy.enabled }}
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {{ include "http-service.name" . }}
  labels:
    {{- include "http-service.labels" . | nindent 4 }}
spec:
  podSelector:
    matchLabels:
      {{- include "http-service.selectorLabels" . | nindent 6 }}
  policyTypes: ["Ingress", "Egress"]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: {{ .Values.networkPolicy.ingressFromNamespace }}
      ports:
        - protocol: TCP
          port: {{ .Values.port }}
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
{{- end }}
EOF
```

6. Validá el chart:

```bash
helm lint platform/golden-paths/http-service --set name=checkout --set image=ghcr.io/acme/checkout:1.4.2
```

```
==> Linting platform/golden-paths/http-service
[INFO] Chart.yaml: icon is recommended

1 chart(s) linted, 0 chart(s) failed
```

### Bloque 3.B — Medir el apalancamiento

7. Escribí la interfaz que ve el developer: **el archivo completo que Dana mantiene**.

```bash
mkdir -p apps/checkout
cat > apps/checkout/app.yaml <<'EOF'
name: checkout
image: ghcr.io/acme/checkout:1.4.2
port: 8080
env:
  LOG_LEVEL: info
EOF
wc -l < apps/checkout/app.yaml
```

```
6
```

8. Medí lo que la plataforma genera y mantiene por ella:

```bash
helm template checkout platform/golden-paths/http-service \
  -f apps/checkout/app.yaml > /tmp/rendered.yaml

grep -vc '^\s*$\|^\s*#' /tmp/rendered.yaml
grep -c '^---' /tmp/rendered.yaml
grep '^kind:' /tmp/rendered.yaml | sort | uniq -c
```

Salida de referencia:

```
178
   5
   1 kind: Deployment
   1 kind: HorizontalPodAutoscaler
   1 kind: NetworkPolicy
   1 kind: PodDisruptionBudget
   1 kind: Service
   1 kind: ServiceAccount
```

9. Calculá el apalancamiento y el nuevo índice de carga cognitiva:

```bash
python3 - <<'EOF'
authored, generated = 6, 178
print(f"leverage ratio       = {generated/authored:.1f}x")
kinds, decisions = 1, 2          # el dev conoce un kind lógico y toma 2 decisiones
print(f"cognitive load index = {kinds*decisions + authored}  (baseline: 398)")
EOF
```

```
leverage ratio       = 29.7x
cognitive load index = 8  (baseline: 398)
```

10. Verificá que el contrato **rechaza** entradas inválidas antes de tocar el cluster:

```bash
helm template bad platform/golden-paths/http-service --set name=Checkout --set image=ghcr.io/acme/checkout
echo "exit=$?"
```

```
Error: values don't meet the specifications of the schema(s) in the following chart(s):
http-service:
- name: does not match pattern '^[a-z]([-a-z0-9]*[a-z0-9])?$'
- image: does not match pattern '^[^:]+:[^:]+$'

exit=1
```

11. Desplegá y medí el **time-to-first-deploy** real:

```bash
kubectl create namespace team-a
kubectl label namespace team-a platform.acme.io/tier=golden-path

time (
  helm upgrade --install checkout platform/golden-paths/http-service \
    -n team-a -f apps/checkout/app.yaml \
    --set image=ghcr.io/nginxinc/nginx-unprivileged:1.27-alpine \
    --set port=8080 --set probes.readinessPath=/ --set probes.livenessPath=/ \
    --wait --timeout 3m
)
kubectl -n team-a get deploy,hpa,pdb,netpol -l platform.acme.io/golden-path=http-service
```

```
Release "checkout" does not exist. Installing it now.
NAME: checkout
STATUS: deployed
REVISION: 1

real    0m41.812s

NAME                       READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/checkout   2/2     2            2           41s

NAME                                           REFERENCE             TARGETS         MINPODS   MAXPODS   REPLICAS
horizontalpodautoscaler.../checkout            Deployment/checkout   <unknown>/70%   2         10        2

NAME                                  MIN AVAILABLE   ALLOWED DISRUPTIONS   AGE
poddisruptionbudget.policy/checkout   1               1                     41s

NAME                                       POD-SELECTOR                    AGE
networkpolicy.networking.k8s.io/checkout   app.kubernetes.io/name=checkout 41s
```

### Preguntas de verificación — bloque 3

**P3.1** El chart genera un `PodDisruptionBudget` que Dana nunca pidió ni conoce. ¿Es esto una plataforma imponiendo política, o un golden path? Justificá con la distinción *paved road* / *mandate*.

**P3.2** ¿Qué hace que este chart sea un *Thinnest Viable Platform* y no simplemente "un chart"? Nombrá dos propiedades del ejercicio que serían igual de necesarias con Crossplane, Backstage o Score.

**P3.3** El `values.schema.json` rechaza `image` sin tag. ¿Por qué esta validación pertenece a la interfaz de la plataforma y no a un policy engine en el cluster? ¿En qué caso sí debe estar en ambos lados?

**P3.4** Un equipo necesita `maxReplicas: 40`, más de lo que el golden path permite. Describí las tres respuestas posibles del platform team y cuál es coherente con "platform as a product".

**P3.5** El apalancamiento medido es 29.7×. ¿Qué costo aparece del lado de la plataforma que este número **no** muestra, y en qué aspecto del maturity model se paga?

**P3.6** ¿Por qué el label `platform.acme.io/golden-path-version` es un requisito de producto y no cosmética?

---

## Ejercicio 4 — Convertir objetivos en números: SLOs de la plataforma y métricas DORA

**Objetivo del ejercicio.** El tema 1.5 exige distinguir tres familias de métricas que se confunden todo el tiempo: **métricas de entrega** (DORA), **métricas de la plataforma como servicio** (SLIs/SLOs propios) y **métricas de producto** (adopción, satisfacción). Acá producís las tres, y descubrís por qué las dos primeras mienten si el tamaño de muestra es chico.

### Bloque 4.A — SLOs de la plataforma misma

1. La plataforma es un servicio de producción: tiene usuarios, tiene caídas y debe tener error budget. Escribí sus reglas:

```bash
mkdir -p platform/observability
cat > platform/observability/slo-golden-path.yaml <<'EOF'
groups:
  - name: platform-golden-path.sli
    interval: 30s
    rules:
      # SLI 1: éxito del golden path (¿la plataforma entrega lo que promete?)
      - record: platform:golden_path_runs:rate5m
        expr: sum by (golden_path) (rate(platform_golden_path_runs_total[5m]))
      - record: platform:golden_path_failures:rate5m
        expr: sum by (golden_path) (rate(platform_golden_path_runs_total{result="failure"}[5m]))
      - record: platform:golden_path_error_ratio:rate5m
        expr: |
          platform:golden_path_failures:rate5m
            /
          clamp_min(platform:golden_path_runs:rate5m, 1e-9)
      - record: platform:golden_path_runs:rate1h
        expr: sum by (golden_path) (rate(platform_golden_path_runs_total[1h]))
      - record: platform:golden_path_failures:rate1h
        expr: sum by (golden_path) (rate(platform_golden_path_runs_total{result="failure"}[1h]))
      - record: platform:golden_path_error_ratio:rate1h
        expr: |
          platform:golden_path_failures:rate1h
            /
          clamp_min(platform:golden_path_runs:rate1h, 1e-9)
      # SLI 2: latencia de provisioning (¿self-service o self-service con espera?)
      - record: platform:provisioning_seconds:p90_30m
        expr: |
          histogram_quantile(
            0.90,
            sum by (le, resource) (rate(platform_provisioning_duration_seconds_bucket[30m]))
          )

  - name: platform-golden-path.slo
    rules:
      # SLO: 99 % de las ejecuciones del golden path terminan OK (budget 1 %).
      # Burn rate rápido: 14.4x consume el budget mensual en ~2 días.
      - alert: GoldenPathErrorBudgetBurnFast
        expr: |
          platform:golden_path_error_ratio:rate1h > (14.4 * 0.01)
            and
          platform:golden_path_error_ratio:rate5m > (14.4 * 0.01)
        for: 2m
        labels:
          severity: page
          slo: golden-path-success
        annotations:
          summary: "El golden path {{ $labels.golden_path }} está quemando error budget 14.4x"
          runbook_url: "https://docs.acme.io/platform/runbooks/golden-path-failures"
      - alert: ProvisioningSlowerThanPromised
        expr: platform:provisioning_seconds:p90_30m > 300
        for: 15m
        labels:
          severity: ticket
          slo: provisioning-latency
        annotations:
          summary: "p90 de provisioning de {{ $labels.resource }} por encima del compromiso de 5 min"
EOF
```

2. Validá sintaxis y semántica de PromQL antes de que llegue al Prometheus de producción:

```bash
promtool check rules platform/observability/slo-golden-path.yaml
```

```
Checking platform/observability/slo-golden-path.yaml
  SUCCESS: 9 rules found
```

3. Probá el efecto del `clamp_min`: quitalo y verás que sin tráfico el ratio es `NaN`, y `NaN > 0.144` es falso — la alerta se queda muda justo cuando el golden path está tan roto que nadie lo usa.

### Bloque 4.B — Métricas DORA sobre historia real

4. Sembrá un repositorio con historia controlada:

```bash
cd /tmp && rm -rf dora-lab && git init -q -b main dora-lab && cd dora-lab
git config user.email dev@acme.io && git config user.name dev

seed() { GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$1" git commit -q --allow-empty -m "$2"; }

seed "2026-07-01T09:00:00" "feat: checkout skeleton"
seed "2026-07-01T15:00:00" "feat: payment adapter"
GIT_COMMITTER_DATE="2026-07-03T18:00:00" git tag -a v1.0.0 -m "release 1.0.0"

seed "2026-07-06T10:00:00" "fix: retry on 502"
seed "2026-07-07T11:00:00" "feat: idempotency keys"
GIT_COMMITTER_DATE="2026-07-10T12:00:00" git tag -a v1.1.0 -m "release 1.1.0"

seed "2026-07-13T09:00:00" "fix: nil deref in refund path"
GIT_COMMITTER_DATE="2026-07-14T09:00:00" git tag -a v1.2.0 -m "release 1.2.0"

git tag --sort=creatordate --list 'v*'
```

```
v1.0.0
v1.1.0
v1.2.0
```

5. Escribí el cálculo de las dos métricas DORA que se pueden derivar de git:

```bash
cat > dora.py <<'PY'
#!/usr/bin/env python3
"""Compute deployment frequency and lead time for changes from git history.

Caveat by design: a git tag is a *release*, not a *deployment*. Replace the tag
source with real deployment events (Argo CD / Flux / CD webhook) before treating
these numbers as DORA metrics.
"""
import statistics
import subprocess
import sys


def sh(*args):
    return subprocess.run(args, capture_output=True, text=True, check=True).stdout.strip()


tags = [t for t in sh("git", "tag", "--sort=creatordate", "--list", "v*").splitlines() if t]
if len(tags) < 2:
    sys.exit("need at least 2 release tags")

lead_times, deploys, prev = [], [], None
for tag in tags:
    # creatordate works for both annotated (tagger date) and lightweight (commit date) tags
    ts = int(sh("git", "for-each-ref", "--format=%(creatordate:unix)", f"refs/tags/{tag}"))
    deploys.append(ts)
    rng = f"{prev}..{tag}" if prev else tag
    for line in sh("git", "log", rng, "--pretty=%ct").splitlines():
        lead_times.append(ts - int(line))
    prev = tag

window_d = (deploys[-1] - deploys[0]) / 86400
print(f"releases                    : {len(deploys)}")
print(f"window                      : {window_d:.3f} d")
print(f"deployment freq (naive)     : {len(deploys) / window_d * 7:.2f} /week")
print(f"deployment freq (intervals) : {(len(deploys) - 1) / window_d * 7:.2f} /week")
print(f"lead time p50               : {statistics.median(lead_times) / 3600:.2f} h")
if len(lead_times) >= 2:
    print(f"lead time p90               : {statistics.quantiles(lead_times, n=10)[8] / 3600:.2f} h")
print(f"lead time max (observed)    : {max(lead_times) / 3600:.2f} h")
print(f"sample size                 : n={len(lead_times)}")
PY
python3 dora.py
```

```
releases                    : 3
window                      : 10.625 d
deployment freq (naive)     : 1.98 /week
deployment freq (intervals) : 1.32 /week
lead time p50               : 57.00 h
lead time p90               : 108.00 h
lead time max (observed)    : 98.00 h
sample size                 : n=5
```

6. Mirá el renglón `p90 = 108.00 h` contra `max = 98.00 h`. Volvé al ejercicio antes de seguir.

7. Volvé al directorio del lab:

```bash
cd ~/cnpa-1.5
```

### Preguntas de verificación — bloque 4

**P4.1** El p90 (108 h) supera al peor lead time observado (98 h). ¿Es un bug del script? Explicá qué pasó y qué lección de *madurez de medición* deja.

**P4.2** Las dos frecuencias de despliegue difieren en 50 % (1.98 vs 1.32 /semana). ¿Cuál reportarías y por qué? ¿Qué pasa con ambas si extendés la ventana a un trimestre fijo?

**P4.3** Este script no puede calcular *change failure rate* ni *failed deployment recovery time*. ¿Qué fuente de datos hace falta, y por qué su ausencia es un síntoma clásico del nivel *Provisional* en el aspecto *Measurement*?

**P4.4** Las métricas DORA miden a los **equipos de producto**, no a la plataforma. Entonces, ¿por qué son objetivos legítimos de un charter de plataforma? ¿Y cuál es el riesgo de convertirlas en target del platform team?

**P4.5** ¿Por qué la alerta `GoldenPathErrorBudgetBurnFast` exige que la ventana de 1 h **y** la de 5 min superen el umbral simultáneamente?

**P4.6** ¿Qué mide `platform:provisioning_seconds:p90_30m` en términos del temario, y qué atributo del CNCF Platforms White Paper deja de cumplirse si ese p90 es de 3 días?

---

## Ejercicio 5 — Autoevaluación con el CNCF Platform Engineering Maturity Model

**Objetivo del ejercicio.** El [CNCF Platform Engineering Maturity Model](https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/) define **cinco aspectos** — *Investment, Adoption, Interfaces, Operations, Measurement* — y **cuatro niveles** — *Provisional (1), Operational (2), Scalable (3), Optimizing (4)*. Acá lo aplicás con evidencia obligatoria: un nivel sin evidencia es una opinión.

### Bloque 5.A — Levantar la evaluación

1. Escribí la autoevaluación de la plataforma que construiste en los ejercicios 2–4:

```bash
cat > platform/product/maturity.yaml <<'EOF'
model: cncf-platform-engineering-maturity-model
assessed_at: "2026-08-06"
assessed_by: [platform-team, two-stream-aligned-teams, security]
aspects:
  investment:
    level: 2
    evidence: >-
      5 FTE dedicados y presupuesto propio de producto (charter §6); todavía no hay
      contribución de los equipos usuarios ni modelo de inner-source.
  adoption:
    level: 1
    evidence: >-
      1 servicio (checkout) sobre el golden path de 34 servicios productivos = 3 %.
      La adopción arrancó por invitación directa, no por demanda entrante.
  interfaces:
    level: 2
    evidence: >-
      Una interfaz declarativa versionada (app.yaml + values.schema.json) con
      validación en el borde; falta portal y catálogo de servicios; sin API programática.
  operations:
    level: 2
    evidence: >-
      El golden path se despliega con Helm y GitOps, con on-call del platform team;
      los upgrades del chart todavía son manuales por consumidor.
  measurement:
    level: 1
    evidence: >-
      Existen SLOs escritos y validados con promtool, pero no hay pipeline de
      deployment events; DORA se estima desde git tags (n=5) y no hay encuesta DX.
EOF
```

2. Escribí el evaluador:

```bash
cat > platform/product/maturity.py <<'PY'
#!/usr/bin/env python3
"""Report the bottleneck aspect of a CNCF platform maturity self-assessment."""
import sys

import yaml

LEVELS = {1: "Provisional", 2: "Operational", 3: "Scalable", 4: "Optimizing"}
ASPECTS = ["investment", "adoption", "interfaces", "operations", "measurement"]

data = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
scores = {}
for aspect in ASPECTS:
    entry = (data.get("aspects") or {}).get(aspect)
    if entry is None:
        sys.exit(f"missing aspect: {aspect}")
    if not str(entry.get("evidence", "")).strip():
        sys.exit(f"aspect '{aspect}' has no evidence: a level without evidence is an opinion")
    level = int(entry["level"])
    if level not in LEVELS:
        sys.exit(f"aspect '{aspect}': level {level} is outside 1..4")
    scores[aspect] = level

worst = min(scores.values())
bottlenecks = [a for a, lv in scores.items() if lv == worst]
width = max(len(a) for a in ASPECTS)

for aspect in ASPECTS:
    lv = scores[aspect]
    bar = "#" * lv + "." * (4 - lv)
    mark = "   <== bottleneck" if aspect in bottlenecks else ""
    print(f"{aspect:<{width}}  [{bar}]  {lv} {LEVELS[lv]}{mark}")

print()
print(f"effective level (weakest aspect) : {worst} {LEVELS[worst]}")
print(f"arithmetic mean (informative)    : {sum(scores.values()) / len(scores):.2f}")
print(f"invest next in                   : {', '.join(bottlenecks)}")
print()
print("Reminder: this model is a conversation tool, not a score or a certification.")
PY
./.venv/bin/python3 platform/product/maturity.py platform/product/maturity.yaml
```

```
investment   [##..]  2 Operational
adoption     [#...]  1 Provisional   <== bottleneck
interfaces   [##..]  2 Operational
operations   [##..]  2 Operational
measurement  [#...]  1 Provisional   <== bottleneck

effective level (weakest aspect) : 1 Provisional
arithmetic mean (informative)    : 1.60
invest next in                   : adoption, measurement

Reminder: this model is a conversation tool, not a score or a certification.
```

3. Probá la regla de la evidencia:

```bash
yq -i '.aspects.adoption.evidence = ""' platform/product/maturity.yaml
./.venv/bin/python3 platform/product/maturity.py platform/product/maturity.yaml; echo "exit=$?"
yq -i '.aspects.adoption.evidence = "1/34 servicios (3 %) sobre el golden path"' platform/product/maturity.yaml
```

```
aspect 'adoption' has no evidence: a level without evidence is an opinion
exit=1
```

### Preguntas de verificación — bloque 5

**P5.1** El script reporta "effective level = el aspecto más débil" y llama al promedio "informative". ¿Por qué promediar los cinco aspectos es peligroso, y qué decisión de inversión induce el promedio 1.60 que es equivocada?

**P5.2** *Investment* está en 2 mientras *Adoption* está en 1. Describí el fracaso concreto que ese patrón anticipa y su nombre habitual como anti-pattern.

**P5.3** Nombrá los cinco aspectos del modelo y, para cada uno, una evidencia observable en un cluster o repositorio (no una opinión).

**P5.4** ¿Qué diferencia hay entre este modelo y un framework de certificación como CMMI, y por qué la CNCF insiste en que no es un ranking?

**P5.5** El nivel *Optimizing* del aspecto *Interfaces* no significa "más features". ¿Qué significa, y cómo se vería en el chart del ejercicio 3?

---

## Ejercicio 6 — Estrategia: build vs buy vs adopt, decidido y documentado

**Objetivo del ejercicio.** Elegir cómo se construye la plataforma es la decisión estratégica del tema. La trampa habitual es resolverla con una matriz ponderada y creer que el número decide. La matriz sirve para **explicitar los pesos**; la decisión la toman la diferenciación estratégica y la reversibilidad.

### Bloque 6.A — Matriz de decisión

1. Modelá la decisión "¿cómo damos self-service de infraestructura (bases de datos, buckets, colas)?":

```bash
mkdir -p platform/decisions
cat > platform/decisions/idp-provisioning.yaml <<'EOF'
decision: "Self-service provisioning de infraestructura para stream-aligned teams"
scale: "0 = pésimo, 1 = excelente"
criteria:            # pesos = lo que la organización realmente valora
  time_to_value: 0.25
  cognitive_load_transferred: 0.20   # cuánta carga saca de encima al platform team
  fit_to_existing_stack: 0.15
  operational_cost_5y: 0.15
  reversibility: 0.15                # qué tan caro es salir de esta decisión
  strategic_differentiation: 0.10    # ¿esto nos distingue en el mercado?
options:
  build_in_house_operator:
    time_to_value: 0.2
    cognitive_load_transferred: 0.3
    fit_to_existing_stack: 1.0
    operational_cost_5y: 0.3
    reversibility: 0.6
    strategic_differentiation: 0.5
  adopt_oss_crossplane:
    time_to_value: 0.7
    cognitive_load_transferred: 0.7
    fit_to_existing_stack: 0.8
    operational_cost_5y: 0.6
    reversibility: 0.8
    strategic_differentiation: 0.2
  buy_commercial_idp:
    time_to_value: 0.9
    cognitive_load_transferred: 0.9
    fit_to_existing_stack: 0.5
    operational_cost_5y: 0.4
    reversibility: 0.3
    strategic_differentiation: 0.1
EOF
```

2. Escribí el evaluador — y notá que su conclusión es deliberadamente humilde:

```bash
cat > platform/decisions/score.py <<'PY'
#!/usr/bin/env python3
"""Weighted decision matrix. The score is an input to the decision, not the decision."""
import sys

import yaml

d = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
criteria = d["criteria"]
total_w = sum(criteria.values())
if abs(total_w - 1.0) > 1e-6:
    print(f"warning: weights sum to {total_w:.3f}, normalising", file=sys.stderr)

rows = []
for option, scores in d["options"].items():
    missing = sorted(set(criteria) - set(scores))
    if missing:
        sys.exit(f"option '{option}' is missing scores for: {missing}")
    rows.append((sum(criteria[c] * scores[c] for c in criteria) / total_w, option))

rows.sort(key=lambda r: r[0], reverse=True)
for score, option in rows:
    print(f"{option:<26} {score:5.3f}  {'#' * round(score * 40)}")

if len(rows) >= 2:
    gap = rows[0][0] - rows[1][0]
    print(f"\ngap {rows[0][1]} vs {rows[1][1]}: {gap:.3f}")
    if gap < 0.05:
        print("=> NOT decisive. Break the tie with reversibility and strategic "
              "differentiation, never with the score.")
PY
./.venv/bin/python3 platform/decisions/score.py platform/decisions/idp-provisioning.yaml
```

```
adopt_oss_crossplane       0.665  ##########################
buy_commercial_idp         0.575  #######################
build_in_house_operator    0.455  ##################

gap adopt_oss_crossplane vs buy_commercial_idp: 0.090
```

3. Hacé el análisis de sensibilidad: si la organización valorara distinto, ¿cambia el ganador?

```bash
yq '.criteria.time_to_value = 0.45 | .criteria.reversibility = 0.05 | .criteria.operational_cost_5y = 0.05' \
   platform/decisions/idp-provisioning.yaml > /tmp/urgent.yaml
./.venv/bin/python3 platform/decisions/score.py /tmp/urgent.yaml
```

```
buy_commercial_idp         0.665  ##########################
adopt_oss_crossplane       0.663  ##########################
build_in_house_operator    0.404  ################

gap buy_commercial_idp vs adopt_oss_crossplane: 0.002
=> NOT decisive. Break the tie with reversibility and strategic differentiation, never with the score.
```

### Bloque 6.B — Registrar la decisión

4. Escribí el ADR en formato [MADR](https://adr.github.io/madr/). Una decisión estratégica sin registro se re-litiga cada seis meses:

```bash
cat > platform/decisions/0001-provisioning-approach.md <<'EOF'
# 0001. Adoptar Crossplane como motor de provisioning, envolverlo en un golden path propio

- Status: accepted
- Date: 2026-08-06
- Deciders: platform-team, head-of-infra, security
- Consulted: 2 stream-aligned teams (checkout, catalog)

## Context and Problem Statement
Los equipos de producto esperan entre 3 y 9 días por infraestructura (bases, colas,
buckets) pedida por ticket. El platform team es el cuello de botella y la espera
domina el lead time (ver métricas DORA, ejercicio 4). ¿Construimos, compramos o
adoptamos OSS?

## Decision Drivers
Pesos y puntuaciones en `idp-provisioning.yaml`; ver análisis de sensibilidad.
El resultado NO fue decisivo entre adoptar y comprar (gap 0.09 y 0.002 según pesos).

## Considered Options
1. Construir un operator propio.
2. Adoptar Crossplane (OSS, CNCF) y componer sobre él.
3. Comprar un IDP comercial llave en mano.

## Decision Outcome
Elegimos **(2) adoptar Crossplane y envolverlo en interfaces propias**, no porque
gane la matriz por poco, sino por dos razones que la matriz no pondera bien:

- **Reversibilidad.** La abstracción que ve el developer es *nuestra*
  (`app.yaml` + CRDs propios). Si Crossplane deja de servir, cambiamos el motor sin
  reescribir los repos de 34 equipos. Comprar el IDP comercial nos ataría a su
  modelo de objetos: es una puerta de una sola dirección.
- **Diferenciación.** Provisionar una base de datos no nos distingue de ningún
  competidor; construir un operator propio sería invertir 5 FTE en un problema
  resuelto. Lo que sí nos diferencia es el catálogo curado y las políticas de la
  compañía, y eso lo construimos nosotros encima.

### Consequences
- Positivas: sin lock-in de interfaz; el motor es reemplazable; la carga de
  mantener reconcilers de cloud sale del platform team.
- Negativas: asumimos la operación de Crossplane (upgrades, CRD versioning) y la
  curva de aprendizaje de Compositions. Presupuestado en el aspecto *Operations*.
- Riesgo aceptado: si la adopción no supera el 30 % en 90 días, revisamos este ADR
  antes de invertir más (criterio de salida explícito).

## Validation
- Métrica de éxito: p50 de provisioning de una base < 10 min al 2026-10-31.
- Métrica de fracaso: > 3 incidentes/mes atribuibles al motor de provisioning.
EOF
```

5. Enlazá la estrategia con la ejecución: agregá al charter el vínculo al ADR.

```bash
printf '\n## 8. Strategic decisions\n- [ADR-0001](../decisions/0001-provisioning-approach.md) — adopt-and-wrap sobre Crossplane.\n' \
  >> platform/product/charter.md
python3 platform/product/validate_charter.py platform/product/charter.md
```

```
OK: 4 objectives, all with metric and deadline
```

### Preguntas de verificación — bloque 6

**P6.1** El ADR elige la opción ganadora de la matriz, pero explícitamente **no** por la matriz. ¿Cuál es el argumento, y por qué un gap de 0.002 en el escenario de sensibilidad debería alarmar a quien iba a decidir por el puntaje?

**P6.2** ¿Qué significa "adopt and wrap" y por qué preserva la reversibilidad? Nombrá exactamente qué activo queda bajo control del platform team.

**P6.3** El criterio *strategic_differentiation* tiene el peso más bajo (0.10) pero termina siendo decisivo. ¿Contradicción? Explicá el rol de los criterios de tipo *filtro* frente a los de tipo *puntaje*.

**P6.4** El ADR fija un criterio de fracaso ("< 30 % de adopción en 90 días → revisar"). ¿Por qué una decisión estratégica de plataforma debe llevar criterio de salida, y con qué aspecto del maturity model se relaciona?

**P6.5** Un compañero propone construir el operator propio "porque nuestro caso es único". ¿Qué pregunta única le hacés para verificar esa afirmación?

---

## Ejercicio 7 — Diagnosticar anti-patterns con datos, no con opiniones

**Objetivo del ejercicio.** Los anti-patterns del tema 1.5 — *plataforma como gatekeeper*, *build it and they will come*, *torre de marfil* — no se detectan preguntando. Se detectan midiendo. Acá los medís sobre el cluster.

### Bloque 7.A — ¿Es self-service o es un ticket con otro nombre?

1. Verificá qué puede hacer un developer hoy:

```bash
kubectl auth can-i --list --as=alice@acme.io --namespace team-a | head -8
kubectl auth can-i create deployments --as=alice@acme.io -n team-a
kubectl auth can-i create namespaces --as=alice@acme.io
```

```
Resources                                       Non-Resource URLs   Resource Names   Verbs
selfsubjectreviews.authentication.k8s.io        []                  []               [create]
selfsubjectaccessreviews.authorization.k8s.io   []                  []               [create]
selfsubjectrulesreviews.authorization.k8s.io    []                  []               [create]
                                                [/healthz]          []               [get]
                                                [/version]          []               [get]

no
no
```

> Dos `no`. Todo despliegue pasa por el platform team: la "plataforma" es una cola de tickets con YAML adentro.

2. Convertí el golden path en un permiso, no en un favor. La clave del diseño: los verbos otorgados son **exactamente** los kinds que el golden path genera, ni uno más:

```bash
cat > platform/rbac/golden-path.yaml <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: platform:golden-path:http-service
  labels:
    platform.acme.io/golden-path: http-service
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["services", "serviceaccounts", "configmaps"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["autoscaling"]
    resources: ["horizontalpodautoscalers"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["policy"]
    resources: ["poddisruptionbudgets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["networkpolicies"]
    verbs: ["get", "list", "watch"]        # las lee, no las escribe: es guardrail
  - apiGroups: [""]
    resources: ["pods", "pods/log", "events"]
    verbs: ["get", "list", "watch"]        # sin observabilidad no hay ownership
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: golden-path-http-service
  namespace: team-a
subjects:
  - kind: User
    name: alice@acme.io
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: platform:golden-path:http-service
  apiGroup: rbac.authorization.k8s.io
EOF
mkdir -p platform/rbac && kubectl apply -f platform/rbac/golden-path.yaml
```

```
clusterrole.rbac.authorization.k8s.io/platform:golden-path:http-service created
rolebinding.rbac.authorization.k8s.io/golden-path-http-service created
```

3. Re-medí:

```bash
for verb_res in "create deployments" "delete deployments" "get pods/log" "create networkpolicies" "create namespaces"; do
  printf '%-26s %s\n' "$verb_res" "$(kubectl auth can-i $verb_res --as=alice@acme.io -n team-a)"
done
```

```
create deployments         yes
delete deployments         yes
get pods/log               yes
create networkpolicies     no
create namespaces          no
```

### Bloque 7.B — ¿Adopción o imposición? ¿Producto o torre de marfil?

4. Medí la adopción real del golden path sobre el cluster, que es la única fuente que no miente:

```bash
cat > platform/observability/adoption.sh <<'EOF'
#!/usr/bin/env bash
# Golden path adoption = deployments carrying the golden-path label / all deployments.
set -euo pipefail
total=$(kubectl get deploy -A --no-headers | wc -l)
paved=$(kubectl get deploy -A -l platform.acme.io/golden-path --no-headers | wc -l)
printf 'deployments total : %s\n' "$total"
printf 'on golden path    : %s\n' "$paved"
awk -v p="$paved" -v t="$total" 'BEGIN { printf "adoption          : %.1f %%\n", (t?100*p/t:0) }'
echo
echo "Off the paved road (the platform backlog, ranked by whoever is suffering):"
kubectl get deploy -A -L app.kubernetes.io/part-of --no-headers \
  | grep -v 'acme-idp' | awk '{print "  - " $1 "/" $2}' | head -10
EOF
chmod +x platform/observability/adoption.sh && ./platform/observability/adoption.sh
```

```
deployments total : 5
on golden path    : 1
adoption          : 20.0 %

Off the paved road (the platform backlog, ranked by whoever is suffering):
  - kube-system/coredns
  - local-path-storage/local-path-provisioner
  - team-a/legacy-report-worker
  - team-b/catalog-api
```

5. Medí la fricción del propio platform team (torre de marfil): ¿cuánto tarda la plataforma en responderle a un usuario? Con la historia del ejercicio 4 ya sabés hacerlo; el mismo `dora.py` corrido sobre el repo de la **plataforma** da su lead time. Una plataforma con peor lead time que sus usuarios no puede pedirles agilidad.

### Preguntas de verificación — bloque 7

**P7.1** El ClusterRole otorga `get, list, watch` sobre `networkpolicies` pero no `create`. Explicá esta asimetría en términos de *golden path* versus *guardrail*.

**P7.2** `create namespaces` sigue en `no` después del cambio. ¿Es esto un gatekeeper residual o un diseño correcto? ¿Cómo se resuelve el namespace-as-a-service sin volver al ticket?

**P7.3** La adopción da 20 %, pero el denominador incluye `coredns` y `local-path-provisioner`. ¿Por qué esa métrica está mal construida y cómo la corregirías? ¿Qué riesgo introduce una métrica de adopción inflada?

**P7.4** La salida lista los deployments "fuera del camino pavimentado" y los llama *backlog*. ¿Qué postura de producto expresa esa palabra, frente a llamarlos "no compliant"?

**P7.5** El platform team propone forzar la adopción con un admission webhook que rechace todo Deployment sin el label `platform.acme.io/golden-path`. Evaluá la propuesta: ¿qué mide bien, qué destruye, y qué haría en su lugar?

**P7.6** ¿Por qué medir el lead time del *propio* repositorio de la plataforma es una prueba de la tesis "platform as a product"?

---

## Ejercicio 8 — Cerrar el ciclo: de aspectos débiles a OKRs de 90 días

**Objetivo del ejercicio.** El tema se llama *Goals, Objectives, and Strategic Approaches*. Falta el paso que la mayoría omite: derivar objetivos **desde el diagnóstico**, no desde las ganas. Los bottlenecks del ejercicio 5 (*adoption*, *measurement*) son el input; los OKRs son el output.

1. Escribí los OKRs, ligados por construcción al aspecto que resuelven:

```bash
cat > platform/product/okr-2026q4.md <<'EOF'
# Platform OKRs — Q4 2026 (2026-10-01 → 2026-12-31)

Derivados de `maturity.yaml`: bottlenecks = adoption (1), measurement (1).
Regla: ningún OKR sin aspecto asociado, ningún key result sin instrumento de medición.

## O1 — Que el golden path sea la forma obvia de desplegar  [aspect: adoption]
- KR1.1 Adopción del golden path 3 % → 40 % de servicios productivos.
  Instrumento: `platform/observability/adoption.sh`, denominador = deployments con
  `app.kubernetes.io/part-of` de un equipo de producto (excluye componentes de sistema).
- KR1.2 p50 de time-to-first-deploy de un servicio nuevo: 9 d → < 4 h.
  Instrumento: timestamp de creación del repo → primer deployment event de Argo CD.
- KR1.3 3 migraciones acompañadas por el platform team en pair, no por documentación.
  Instrumento: registro de sesiones; cada una produce un item de backlog.

## O2 — Medir la plataforma como se mide un servicio de producción  [aspect: measurement]
- KR2.1 Deployment events emitidos por Argo CD hacia el warehouse; DORA calculado
  sobre despliegues reales, no sobre git tags. n ≥ 200 despliegues/trimestre.
- KR2.2 Change failure rate instrumentado (rollback / hotfix tag) y publicado semanal.
- KR2.3 Encuesta DX ejecutada con ≥ 70 % de respuesta; publicada íntegra, incluidas
  las respuestas malas.

## Non-objectives de este trimestre (para que O1 y O2 sean posibles)
- No agregamos soporte de workloads con estado.
- No construimos portal web: la interfaz declarativa vigente alcanza para 40 %.

## Anti-goals (lo que NO haremos aunque suba la métrica)
- No forzaremos la adopción por admission webhook. Un número de adopción obtenido
  por bloqueo deja de ser señal de calidad del producto.
EOF
```

2. Verificá la trazabilidad completa: cada OKR debe rastrearse hasta una medición, y cada medición hasta un objetivo del charter.

```bash
grep -c 'aspect:' platform/product/okr-2026q4.md
grep -c 'Instrumento:' platform/product/okr-2026q4.md
ls platform/product platform/decisions platform/observability platform/golden-paths/http-service
```

```
2
5
```

### Preguntas de verificación — bloque 8

**P8.1** El documento tiene *non-objectives* **y** *anti-goals*, que no son lo mismo. Distinguilos y explicá por qué el anti-goal sobre el admission webhook es el más importante del trimestre.

**P8.2** KR1.1 redefine el denominador de la métrica de adopción respecto del ejercicio 7. ¿Es legítimo cambiar la definición de una métrica a mitad de camino? ¿Bajo qué condición?

**P8.3** ¿Por qué KR2.1 ("emitir deployment events") es prerrequisito de casi todo lo demás, y qué significa que un trimestre entero de una plataforma se dedique a instrumentación?

**P8.4** KR1.3 propone acompañar 3 migraciones *en pair* en lugar de escribir documentación. En términos de Team Topologies, ¿qué modo de interacción es ése, por qué es temporal, y a qué modo debe converger?

**P8.5** Un director pide agregar un KR: "reducir el costo de cloud un 20 %". ¿Cabe en estos OKRs? Argumentá desde el charter.

---

<details>
<summary><strong>Respuestas</strong> — abrir después de haber ejecutado los ejercicios</summary>

### Ejercicio 1

**R1.1** Porque no es medible ni acotado: no dice de quién, respecto de qué línea base, ni cuándo. El aspecto *Measurement* del maturity model exige que los objetivos de la plataforma tengan instrumento de medición y línea base; sin eso no se puede saber si la inversión produjo valor, ni decidir cuándo parar. Un objetivo válido es "bajar de 214 a menos de 15 las líneas de YAML que un equipo mantiene por servicio, para el 2026-10-31", con la medición definida. Además, la carga cognitiva es un medio, no un fin: el fin es el outcome de negocio (entregar más rápido y con menos riesgo).

**R1.2** La plataforma ataca la carga **extrínseca**: el accidente de la implementación — sintaxis de YAML, límites de recursos, versiones de API, topología de red, plumbing de CI. La **intrínseca** es la complejidad irreducible del dominio del equipo (cómo funciona el checkout, qué es una autorización de tarjeta): eliminarla sería quitarle al equipo su razón de ser. La **germane/pertinente** es el esfuerzo de aprender el dominio y mejorar el diseño: una plataforma que la elimina impide que el equipo crezca. Si la plataforma intenta absorber la intrínseca, termina codificando reglas de negocio ajenas y se vuelve un cuello de botella con conocimiento que no le pertenece.

**R1.3** No la reduce, la **traslada** y la vuelve más cara. La carga total del sistema sube: el developer ahora debe aprender el formato del ticket, esperar, traducir su intención a la de otro equipo y depurar a ciegas, mientras el platform team acumula contexto que no tiene. El anti-pattern es la **plataforma como gatekeeper** (o "ticket-driven platform"): destruye el atributo de *self-service on-demand* del CNCF Platforms White Paper y convierte al platform team en cuello de botella del lead time.

**R1.4** Porque cuenta campos del API, no decisiones que un humano toma: la mayoría de esos campos tienen defaults razonables y nunca se tocan, y el conteo no distingue entre "campo que existe" y "campo que me obliga a elegir". La medición real es conductual: tiempo hasta el primer deploy de una persona nueva (TTFD), cantidad de decisiones sin default seguro que el developer debe tomar, cantidad de sistemas distintos que debe abrir para desplegar, y encuestas DX de percepción (el marco SPACE) contrastadas con la telemetría del flujo.

### Ejercicio 2

**R2.1** Expresa **enable, don't enforce**: el golden path es un camino pavimentado (paved road), no un mandato. Es la piedra angular del enfoque *platform as a product* porque la adopción voluntaria es la única señal honesta de que el producto es bueno. Si la plataforma es obligatoria, la métrica de adopción se satura en 100 % sin decir nada sobre calidad, se pierde el mecanismo de feedback (los usuarios ya no pueden "votar con los pies"), y el platform team empieza a optimizar cumplimiento en lugar de utilidad. La excepción legítima no es el golden path sino el **guardrail** de seguridad/compliance, que sí se impone —pero se impone a todos los caminos, no como forma de forzar el uso de la plataforma.

**R2.2** Porque el alcance define el producto tanto como las features. Sin non-goals, cada pedido entrante parece razonable en aislamiento, la plataforma acepta workloads con estado, batch, ML, legacy y multi-cloud a la vez, el equipo se dispersa, la calidad de todos los caminos baja y ninguno queda pavimentado. Ejemplo concreto: aceptar bases de datos con estado dentro del golden path obliga a resolver backups, restore, upgrades de motor y PITR; eso consume el trimestre entero y el objetivo O1 (time-to-first-deploy) no se cumple para nadie, incluidos los servicios stateless que eran el 80 % del tráfico.

**R2.3** El aspecto *Investment* del CNCF Platform Engineering Maturity Model describe justamente cómo se financia y dota de personal la plataforma: en el nivel *Provisional* es trabajo voluntario o esfuerzo de un individuo sin presupuesto; en *Operational* hay un equipo dedicado; en *Scalable* la inversión se ajusta a la demanda de los usuarios y aparecen contribuciones de los equipos consumidores (inner-source); en *Optimizing* la inversión se decide con datos de uso y valor. Un funding model de "costo prorrateado por proyecto" impide tener roadmap propio y obliga a priorizar por quien grita más fuerte: es techo estructural de madurez, no un detalle contable.

**R2.4** Es **leading** respecto de O1. Ninguna mejora de lead time atribuible a la plataforma puede materializarse antes de que haya gente usándola; la adopción se mueve primero y el efecto en DORA llega después. Es la métrica que más rápido detecta un producto equivocado porque una plataforma sin usuarios es indistinguible de una plataforma inexistente, y la adopción estancada es el síntoma temprano del anti-pattern *build it and they will come*: se puede ver en semanas, mientras que el lead time necesita trimestres de datos.

**R2.5** Debe tenerlo. La distinción es entre **quién sufre la decisión** y **quién la toma**: el PDB es una decisión de confiabilidad con un default sano que el platform team posee, versiona y puede mejorar para los 34 servicios a la vez. Vive en `values.yaml` del golden path, bajo control del platform team, con un mecanismo de override documentado para quien tenga un requisito real. Ése es exactamente el valor del camino pavimentado: el developer obtiene la buena práctica sin tener que aprenderla, y la organización puede corregirla en un solo lugar.

### Ejercicio 3

**R3.1** Es un **golden path**, no una imposición, y la prueba es doble: (a) Dana puede salirse — nada le impide desplegar sin el chart, el chart no bloquea; (b) el valor lo posee y mantiene el platform team, no se le delega a Dana la decisión. Un *mandate* sería un admission webhook que rechaza Deployments sin PDB; un *paved road* es que el camino fácil ya lo traiga. La diferencia práctica: en el mandate, el equipo que necesita una excepción está bloqueado y abre un ticket; en el paved road, sale del camino y asume el costo visiblemente, lo que además le da al platform team una señal de qué falta en el producto.

**R3.2** Es un TVP porque (a) resuelve **un** caso — servicio HTTP stateless — y declara explícitamente que no resuelve los otros, y (b) es lo más delgado que ya entrega valor de punta a punta: de `app.yaml` a pods corriendo, sin pasos manuales. Las dos propiedades que se mantienen con cualquier tecnología son: **una interfaz mínima con contrato verificable** (el developer declara intención, no implementación, y la entrada se valida en el borde) y **defaults opinados propiedad del platform team, versionados** (para poder mejorar los 34 servicios en un lugar). Con Backstage serían Software Templates + catálogo; con Crossplane, Compositions + XRDs; con Score, el `score.yaml` y su provisioner. La tecnología cambia, esas dos propiedades no.

**R3.3** Porque el objetivo de la interfaz es **fallar rápido y explicar**: el error aparece en el laptop de Dana, en segundos, con el nombre del campo, antes del commit — un ciclo de feedback de segundos en vez de minutos. Un rechazo en el admission controller llega tarde, con un mensaje escrito para operadores, y a veces con recursos parcialmente aplicados. Debe estar en **ambos** lados cuando la regla es de seguridad o compliance: la validación de la interfaz es una comodidad para el usuario y se puede evitar (nadie está obligado a usar el chart), así que la política que la organización realmente necesita garantizar tiene que estar además como guardrail en el cluster —policy as code— para todos los caminos, no solo el pavimentado. Interfaz = UX; admission = garantía.

**R3.4** Las tres respuestas: **(1)** negarlo ("el golden path es así") — convierte el producto en imposición y empuja al equipo fuera de la plataforma con resentimiento; **(2)** hacer un fork/excepción a mano para ese equipo — resuelve hoy y crea una variante sin dueño que nadie actualiza; **(3)** tratarlo como feedback de producto: subir el máximo permitido si 40 es razonable para todos, o exponer `maxReplicas` como campo del contrato con un límite superior justificado. La respuesta coherente con *platform as a product* es la **(3)**, y la pregunta que la guía es "¿este equipo es un caso raro o el primero de muchos?". Además, si el equipo decide salirse del camino, la plataforma no debe bloquearlo: debe hacer visible qué pierde.

**R3.5** No muestra el costo de **operar el camino pavimentado**: versionado del chart, migraciones cuando cambia un default, política de deprecación, soporte, on-call, documentación y pruebas de compatibilidad hacia atrás. Ese costo es real y crece con la cantidad de consumidores; se paga en el aspecto **Operations** del maturity model (y se financia en *Investment*). Es la razón por la que un TVP delgado gana a una plataforma amplia: cada abstracción agregada es un pasivo perpetuo, no un activo de una sola vez.

**R3.6** Porque una plataforma es un producto **versionado**, y sin saber qué versión corre cada consumidor no se puede: estimar el radio de impacto de un cambio de default, ejecutar una deprecación por etapas, diagnosticar un incidente ("¿los que fallan son los de 0.1.x?"), ni medir adopción de mejoras. Etiquetar la versión en los objetos generados es lo que convierte el chart en un producto con inventario, en vez de un template copiado en el tiempo.

### Ejercicio 4

**R4.1** No es un bug. `statistics.quantiles(..., method='exclusive')` —el default— estima cuantiles de la *población* asumiendo que la muestra no contiene los extremos, e **interpola/extrapola** más allá del máximo observado cuando la muestra es diminuta (n=5: la posición del decil 9 cae fuera del rango de datos y se extrapola a 108 h). La lección de madurez de medición es que **un percentil calculado sobre n=5 no es información, es ruido con decimales**: publicar "p90 = 108 h" en un dashboard ejecutivo produce decisiones sobre un número inventado. Nivel *Operational* de *Measurement* significa, entre otras cosas, reportar el tamaño de muestra y el intervalo de confianza junto al valor, o directamente no reportar percentiles hasta tener volumen (por eso el script imprime `sample size` y `max observed`).

**R4.2** La honesta es la de **intervalos** (1.32/semana): con 3 releases hay solo 2 intervalos observados, y la ventana medida de primer a último tag no incluye el tiempo previo al primero ni posterior al último, así que dividir 3 por ese lapso cuenta un evento de más. Yo reportaría la de intervalos, o mejor, cambiaría a una **ventana calendaria fija** (p. ej. los últimos 90 días) y contaría eventos dentro de ella: es lo que hace DORA y lo único comparable entre trimestres y entre equipos. Con una ventana fija, ambas fórmulas convergen a medida que crece el número de despliegues, y la diferencia entre ellas —hoy 50 %— se vuelve despreciable: la discrepancia es un artefacto del tamaño de muestra, igual que en R4.1.

**R4.3** Hace falta una fuente de eventos de **despliegue y de fallo en producción**: eventos de la herramienta de CD (Argo CD, Flux, el pipeline), correlacionados con incidentes o rollbacks (tickets de incidente, tags de hotfix, reversiones automáticas). Git no los tiene porque un tag es un *release*, no un *deployment*: nada garantiza que v1.1.0 haya llegado a producción, ni cuándo, ni si volvió atrás. Su ausencia es el síntoma canónico del nivel **Provisional** en *Measurement*: hay métricas obtenidas de lo que estaba a mano en vez de instrumentación deliberada del flujo de valor, y por lo tanto no se puede saber si la plataforma mejora las cosas.

**R4.4** Son legítimas porque son las métricas de **outcome** que la plataforma existe para mover: la plataforma no tiene valor propio, su valor es el desempeño de entrega de los equipos que la usan (y de ahí, el resultado de negocio). Ponerlas en el charter obliga al platform team a justificar su existencia en términos de sus usuarios y no de sus outputs. El riesgo, si se convierten en target del platform team, es la ley de Goodhart y la atribución falsa: DORA depende de decisiones de arquitectura, de dotación y de proceso que el platform team no controla; un equipo perseguido por esas cifras empieza a presionar a los equipos de producto para desplegar más seguido o a redefinir "deployment". La mitigación es leerlas como métricas **guía y compartidas** —con la adopción como métrica propia— y acompañarlas con instrumentos cualitativos (SPACE, encuesta DX).

**R4.5** Es la técnica de **multiwindow, multi-burn-rate** del SRE Workbook. La ventana larga (1 h) da confianza estadística de que el consumo de error budget es real y no un pico aislado; la ventana corta (5 min) sirve de condición de **reset**: cuando el problema se resuelve, el ratio de 5 min baja de inmediato y la alerta se apaga sola, en vez de quedar disparada una hora entera por un incidente ya cerrado. Con solo la ventana larga se obtienen alertas lentas en detección y lentísimas en recuperación; con solo la corta, ruido. La conjunción da detección rápida con pocas falsas alarmas.

**R4.6** Mide la **latencia del self-service**: cuánto tarda la plataforma en entregar lo que promete cuando alguien lo pide, sin intervención humana. Es el SLI que distingue "self-service" de "ticket automatizado". Si el p90 es de 3 días, la plataforma incumple el atributo **self-service / on-demand** del CNCF Platforms White Paper: aunque la interfaz sea declarativa y no haya un ticket formal, el usuario planifica su trabajo alrededor de la espera, exactamente igual que con el ticket. La forma no importa, el tiempo sí.

### Ejercicio 5

**R5.1** Porque los aspectos no son intercambiables ni compensables: una plataforma con *Investment* excelente y *Adoption* nula no está "a mitad de camino", está fracasando. El promedio permite que la fortaleza en lo fácil de mover (invertir dinero, agregar interfaces) enmascare la debilidad en lo difícil (que la usen, medirla). La decisión equivocada que induce un 1.60 es *"estamos cerca del nivel 2, empujemos un poco más de lo mismo"* — típicamente más features y más presupuesto — cuando el diagnóstico real dice que hay que **dejar de construir e ir a buscar usuarios e instrumentación**. Por eso el script llama "efectivo" al mínimo: la plataforma se comporta como su aspecto más débil.

**R5.2** Anticipa el fracaso de una plataforma cara, técnicamente sólida y sin usuarios: el equipo dedicado sigue construyendo capacidades porque tiene presupuesto, la brecha con la demanda real crece, y cuando llega el recorte de costos la plataforma no puede demostrar valor y se cancela. El anti-pattern es **"build it and they will come"** (y su primo, la **torre de marfil**: decisiones tomadas sin hablar con los usuarios). El correctivo es de producto, no técnico: entrevistas, acompañar migraciones reales, elegir el caso de uso más transitado y hacerlo indiscutiblemente mejor que la alternativa artesanal.

**R5.3** Los cinco aspectos y una evidencia observable de cada uno:
- **Investment** — cómo se financia y dota: existencia de un presupuesto/roadmap propio y FTE asignados; en el repo, un charter con funding model y commits del equipo dedicado.
- **Adoption** — cómo llegan y se quedan los usuarios: porcentaje de deployments con el label del golden path sobre el total de servicios de producto; crecimiento mes a mes.
- **Interfaces** — cómo se consume: existencia de una interfaz declarativa versionada con schema (`values.schema.json`), catálogo/portal, política de deprecación registrada.
- **Operations** — cómo se opera y evoluciona: la plataforma tiene on-call, SLOs, runbooks, upgrades automatizados de sus propios componentes; en el cluster, reconciliación GitOps en lugar de `kubectl apply` manual.
- **Measurement** — cómo se aprende: pipeline de deployment events, SLOs con error budget, encuesta DX periódica con tasa de respuesta publicada.

**R5.4** CMMI-like frameworks certifican y comparan organizaciones contra un estándar, con niveles que se "alcanzan" y se auditan. El modelo de la CNCF es explícitamente una **herramienta de conversación y autoevaluación**: sirve para que un equipo y sus stakeholders acuerden dónde están, cuál es el próximo problema a resolver y por qué, no para exhibir un número. No es un ranking porque el nivel adecuado depende del contexto —una empresa de 40 personas puede estar perfectamente en *Operational* y no tener ninguna razón de negocio para subir—, y porque perseguir el nivel como objetivo produce justo la patología del ejercicio: invertir en el aspecto fácil de puntuar en vez del que duele.

**R5.5** Significa que las interfaces se ajustan a los usuarios y se **retiran** cuando dejan de servir: hay más de una modalidad de consumo para audiencias distintas (declarativa, CLI, API, portal), la evolución se guía con datos de uso, existe política de versionado y deprecación ejecutada de verdad, y el equipo elimina abstracciones que ya nadie necesita. En el chart del ejercicio 3 se vería como: telemetría de qué campos del contrato se usan realmente; retiro de opciones que nadie tocó en dos trimestres; una migración de `0.1.x` a `0.2.0` ejecutada por la plataforma —no por los 34 equipos— con ventana de compatibilidad anunciada; y una API/CRD equivalente para quien no quiera Helm. Más features es, casi siempre, el movimiento opuesto.

### Ejercicio 6

**R6.1** El argumento es que la matriz no pondera bien dos cosas de naturaleza distinta al resto: la **reversibilidad** (costo de deshacer la decisión) y la **diferenciación estratégica** (si esto nos distingue o no). Un gap de 0.002 sobre puntuaciones asignadas a ojo está muy por debajo del error de estimación de los propios inputs: el "ganador" es ruido. Descubrir que un cambio razonable de pesos da vuelta el resultado prueba que la matriz **no está decidiendo**, está revelando que ambas opciones son comparables en lo cuantificable — y que la decisión debe apoyarse en el criterio cualitativo. Usar la matriz para blindar la decisión ("lo dice el modelo") es peor que no tenerla, porque oculta el juicio detrás de un número.

**R6.2** "Adopt and wrap" es adoptar un motor existente (OSS o comercial) para el trabajo pesado y **envolverlo en una interfaz propia** que es la única que ven los usuarios. Preserva la reversibilidad porque el acoplamiento de los 34 repositorios es contra la abstracción propia (`app.yaml`, los CRDs de la compañía), no contra el modelo de objetos del proveedor: cambiar el motor implica reescribir la implementación de la plataforma —trabajo acotado del platform team— y no coordinar una migración de toda la organización. El activo que queda bajo control es **la interfaz de usuario de la plataforma y su contrato**: el punto de acoplamiento. La regla general del temario: acoplá tu implementación a lo que quieras, pero nunca acoples a tus usuarios a algo que no controlás.

**R6.3** No hay contradicción: hay dos tipos de criterio. Los de **puntaje** (time to value, costo, fit) se promedian y son sustituibles entre sí — un poco menos de esto compensa un poco más de aquello. Los de **filtro/veto** son cualitativos y actúan como reglas: "no construimos lo que no nos diferencia", "no tomamos decisiones irreversibles sin necesidad". Meter un criterio de filtro en la suma ponderada lo diluye y le da un peso arbitrario; su función real es descartar opciones o desempatar, no sumar décimas. La forma correcta es aplicar los filtros primero (o al final, como desempate declarado), y usar la matriz solo entre las opciones que sobreviven.

**R6.4** Porque una decisión estratégica de plataforma es una **apuesta bajo incertidumbre**, y sin criterio de salida definido de antemano se vuelve inmune a la evidencia: la organización sigue invirtiendo por costo hundido y por identidad ("ya somos la empresa de Crossplane"). Fijar "si la adopción no supera 30 % en 90 días, revisamos" transforma la decisión en un experimento con condición de parada, y obliga a que exista la instrumentación para evaluarlo. Se relaciona directamente con **Measurement** (hay que poder medir la condición) y con **Investment** (la inversión se ajusta según la evidencia de valor, que es justamente lo que distingue los niveles altos de ese aspecto).

**R6.5** *"¿Qué requisito nuestro no puede satisfacer ninguna de las tres alternativas, y con qué evidencia lo probaste?"* — es decir, pedir el caso concreto y verificado, no la sensación de unicidad. Casi siempre la respuesta cae en una de tres categorías: (a) el requisito sí está cubierto y no se investigó; (b) es un requisito autoimpuesto por una decisión previa que se puede cambiar más barato que construir un operator; (c) es real y específico, y entonces la respuesta correcta rara vez es construir todo, sino construir **solo esa pieza** encima de un motor adoptado. La pregunta también obliga a explicitar el costo de oportunidad: 5 FTE durante un año resolviendo un problema ya resuelto por la industria.

### Ejercicio 7

**R7.1** El **golden path** es lo que el developer puede hacer por sí mismo: crear y borrar sus Deployments, Services, HPA, PDB — todo lo que constituye su servicio y cuyo dueño es él. El **guardrail** es lo que la plataforma garantiza y él no puede desactivar: la NetworkPolicy la escribe la plataforma (a través del chart aplicado por GitOps o por un controller), y el developer solo puede **leerla**. El permiso de lectura es deliberado y no cosmético: sin poder ver la política que le está bloqueando el tráfico, el developer no puede diagnosticar su propio incidente y vuelve a depender de un ticket — el guardrail sería opaco y reintroduciría el gatekeeper por la puerta de atrás. Regla: guardrails invisibles no, guardrails inmutables sí.

**R7.2** Es diseño correcto **solo si** existe otro camino para obtener un namespace sin intervención humana; si no existe, es gatekeeper residual y el más caro de todos, porque bloquea el minuto cero de cada servicio nuevo. `create namespaces` a nivel cluster es un permiso peligroso (permite pisar `kube-system`-adyacentes, evadir cuotas, romper convenciones de nombres). La solución de namespace-as-a-service es una **abstracción de nivel superior con reconciliación**: el equipo declara su intención en un recurso que sí puede crear (un CR `Environment`/`Workspace`, un PR a un repo GitOps, o un `SubnamespaceAnchor` del Hierarchical Namespace Controller), y un controller con los permisos elevados crea el namespace ya con labels, quota, LimitRange, NetworkPolicy default-deny y RoleBinding. El humano nunca es parte del camino: es self-service con guardrails, no delegación de un permiso peligroso.

**R7.3** Está mal construida porque el denominador mezcla **componentes de sistema** (coredns, local-path-provisioner, ingress controllers, operadores) con **servicios de producto**, que son los únicos usuarios potenciales del golden path. Ningún componente de sistema va a adoptarlo nunca, así que la métrica tiene un techo estructural por debajo de 100 % y su valor depende del ruido de infraestructura del cluster. La corrección: definir el denominador como los deployments que pertenecen a un equipo de producto (por ejemplo, filtrando por namespaces etiquetados `platform.acme.io/tier` o por `app.kubernetes.io/part-of` de un catálogo de servicios), y documentar la definición junto a la métrica. El riesgo de una adopción inflada —contar mal el numerador, o incluir servicios que solo tienen el label— es el peor posible para un platform team: se declara victoria, se corta la inversión en producto, y la brecha entre la plataforma y las necesidades reales sigue creciendo sin señal de alarma.

**R7.4** Expresa la postura de **producto**: si un servicio no está en el camino pavimentado, la hipótesis por defecto es que **el camino todavía no le sirve**, y eso es trabajo pendiente de la plataforma. Llamarlos "no compliant" invierte la carga y la culpa: convierte a los usuarios en infractores, al platform team en auditor, y transforma el producto en un régimen. Esa diferencia de vocabulario predice el comportamiento del equipo: el primero produce entrevistas y features; el segundo produce webhooks y reuniones de excepción. Además, la lista ordenada "por quién está sufriendo" es literalmente un backlog priorizado por valor de usuario, que es como se prioriza un producto.

**R7.5** Mide bien una cosa: que la organización quiere consistencia y guardrails. Destruye tres: **(a)** la señal de adopción — con el webhook, el 100 % de adopción no dice nada sobre si la plataforma es buena; **(b)** el feedback loop — los equipos que hoy se salen del camino son la fuente de información más valiosa sobre qué falta, y el webhook los silencia (o los empuja a workarounds peores: sidecars, jobs, cluster propio); **(c)** la relación de producto — la plataforma pasa de proveedor a policía, y con ella la disposición de los equipos a colaborar. En su lugar: separar guardrail de golden path. Los requisitos innegociables (no correr como root, tener resource limits, tener NetworkPolicy) se imponen como **política para todos los caminos** con un policy engine, con mensajes que explican y ofrecen el camino fácil; la adopción del golden path se gana haciéndolo la opción más cómoda, e instrumentando por qué cada servicio de la lista todavía no lo usa. Si tras eso la adopción sigue baja, el problema es el producto, y el webhook lo habría tapado.

**R7.6** Porque un producto se juzga por su capacidad de responder a sus usuarios, y el lead time del repositorio de la plataforma es exactamente esa capacidad medida en tiempo. Si el platform team tarda tres semanas en publicar un cambio de un default que un equipo pidió, su ciclo de aprendizaje es más lento que el de sus usuarios y no puede iterar sobre el feedback que recolecta. Además es la prueba de coherencia: un equipo que exige despliegues frecuentes, pruebas automatizadas y baja fricción a los demás mientras opera su propio código con procesos manuales no tiene credibilidad — y, dato práctico, su plataforma se vuelve el cuello de botella del lead time de todos los demás. Comerse la propia comida ("dogfooding") no es un gesto simbólico: es la única forma de sentir la fricción antes que los usuarios.

### Ejercicio 8

**R8.1** Un **non-objective** es algo valioso que simplemente no se hace **este trimestre**, por foco: soporte de estado y portal web podrían ser objetivos del próximo. Un **anti-goal** es algo que no se hará **nunca por esta vía**, porque hacerlo destruiría la validez de los propios objetivos: el anti-goal del admission webhook impide "cumplir" KR1.1 forzando el label. Es el más importante del trimestre porque protege la **integridad de la métrica que gobierna todo el plan**: existe un atajo barato y técnicamente trivial para llevar la adopción a 40 % sin mejorar nada, y bajo presión de fin de trimestre alguien lo va a proponer con buenos argumentos. Escribirlo antes, cuando nadie está bajo presión, es lo que lo hace vinculante.

**R8.2** Es legítimo cuando la definición vieja era **defectuosa** —como acá, con componentes de sistema en el denominador— y siempre que se cumplan tres condiciones: se documenta el cambio con su justificación, se **recalcula la línea base** con la nueva definición (por eso el KR dice 3 %, no 20 %), y se reportan ambas series durante la transición para que nadie confunda una mejora de definición con una mejora de resultado. Lo ilegítimo es redefinir una métrica *después* de conocer el resultado y en la dirección que conviene, sin recalcular la base: eso es exactamente cómo un dashboard deja de ser un instrumento y pasa a ser propaganda.

**R8.3** Porque sin eventos de despliegue reales no se puede calcular ningún DORA honesto (R4.3), no se puede evaluar KR1.2, ni el criterio de salida del ADR-0001, ni saber si el golden path mejoró algo: todos los demás objetivos quedan sin instrumento. Que una plataforma dedique un trimestre a instrumentación no es una desviación del trabajo "real": significa que reconoce que estaba operando a ciegas — nivel *Provisional* en *Measurement* — y que cualquier inversión posterior sería una apuesta sin forma de evaluarla. Es la aplicación directa del ejercicio 5: se invierte en el aspecto más débil, no en el más cómodo.

**R8.4** Es el modo **collaboration** (colaboración estrecha y temporal entre el platform team y el stream-aligned team). Es deliberadamente temporal porque es caro en carga cognitiva para ambos lados y no escala a 34 equipos; su propósito es descubrir la fricción real —lo que ninguna documentación revela— y convertirla en producto. Debe converger a **X-as-a-Service**: el equipo consume la plataforma con interacción mínima, autoservicio y sin necesidad de hablar con el platform team. La señal de que la convergencia funciona es que cada migración acompañada requiere menos horas que la anterior; si la tercera cuesta lo mismo que la primera, la plataforma no está absorbiendo el aprendizaje y el modo colaboración se está volviendo permanente — que es, otra vez, el gatekeeper con mejor onda.

**R8.5** No cabe **como está formulado**, y el argumento sale del charter: los objetivos de la plataforma son *time-to-first-deploy*, *adopción*, *carga cognitiva* y *disponibilidad*; el costo de cloud no aparece porque el problema declarado es el lead time, no el gasto. Agregarlo ahora tiene tres problemas: compite por los mismos 5 FTE justo cuando el diagnóstico dice que hay que invertir en adopción y medición; no es controlable por la plataforma (el gasto lo generan decisiones de arquitectura y de tráfico de los equipos de producto); y entra en tensión directa con O1, porque la vía rápida para bajar costo es apretar límites y cuotas, o sea, agregar fricción y frenar la adopción. La respuesta constructiva no es negarse: es (a) ofrecer el paso previo, que es **visibilidad** de costo por servicio en el golden path —un habilitador barato, alineado con *Measurement*, que le da a cada equipo el dato para decidir—, y (b) proponerlo como objetivo con nombre propio para el próximo trimestre, con su línea base y su dueño, en lugar de colgarlo de un trimestre cuyo foco ya está comprometido. Si la dirección insiste en que es la prioridad del trimestre, eso es una decisión legítima de negocio: entonces se cambia el charter y se dice explícitamente qué objetivo se posterga, en vez de agregar un quinto KR y fingir que los cinco se van a cumplir.

</details>

---

## Fuentes

- CNCF, *Cloud Native Platform Engineering Associate (CNPA) Curriculum* — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- CNCF TAG App Delivery, *Platforms White Paper* (definición de plataforma, atributos, capacidades y valor) — https://tag-app-delivery.cncf.io/whitepapers/platforms/
- CNCF TAG App Delivery, *Platform Engineering Maturity Model* (aspectos Investment/Adoption/Interfaces/Operations/Measurement; niveles Provisional→Optimizing) — https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/
- DORA, *DORA's software delivery metrics: the four keys* — https://dora.dev/guides/dora-metrics-four-keys/
- Google SRE, *The Site Reliability Workbook*, cap. 5 "Alerting on SLOs" (multiwindow multi-burn-rate) — https://sre.google/workbook/alerting-on-slos/
- Skelton & Pais, *Team Topologies* (carga cognitiva, platform team, modos de interacción X-as-a-Service / collaboration) — https://teamtopologies.com/key-concepts
- Kubernetes, *Using RBAC Authorization* — https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Kubernetes, *Recommended Labels* — https://kubernetes.io/docs/concepts/overview/working-with-objects/common-labels/
- Prometheus, *Recording rules* y *promtool* — https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/
- Helm, *Schema files (`values.schema.json`)* — https://helm.sh/docs/topics/charts/#schema-files
- MADR, *Markdown Any Decision Records* — https://adr.github.io/madr/
- Backstage, *Software Templates* (golden paths como producto) — https://backstage.io/docs/features/software-templates/
- Score, *Workload specification* (interfaz declarativa portable) — https://docs.score.dev/docs/
- Crossplane, *Compositions y Composite Resource Definitions* — https://docs.crossplane.io/latest/concepts/compositions/
- Hierarchical Namespace Controller, *Concepts* (namespace-as-a-service) — https://github.com/kubernetes-sigs/hierarchical-namespaces