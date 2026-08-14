# Tema 4.3 — Configuración común de políticas para las reglas de Kyverno

## Ejercicios Guiados

> **Contexto de examen (KCA).** Los "ajustes comunes de política" son los campos bajo el `spec` de una política que gobiernan *cómo* se evalúa y aplica una regla, con independencia de si la regla es `validate`, `mutate`, `generate` o `verifyImages`. Estos ajustes deciden si una violación bloquea una solicitud o solo la reporta, si la política se ejecuta sobre recursos preexistentes, y cómo se comporta el webhook de admisión cuando el propio Kyverno es inalcanzable. Configurarlos mal es la diferencia entre una política que no hace nada en silencio y una que deja a todo el cluster sin poder programar Pods.

### Prerrequisitos

Necesitás un cluster funcionando y una instalación de Kyverno (controladores de admisión, background y reports). Los ejercicios de abajo son autocontenidos; cada manifiesto está completo y se aplica tal cual.

```bash
# 1. Confirm Kyverno is installed and all controllers are Ready.
kubectl get pods -n kyverno
```

Esperado (los nombres de componentes pueden llevar un sufijo de release):

```
NAME                                             READY   STATUS    RESTARTS   AGE
kyverno-admission-controller-7d9f8c6b4-abcde     1/1     Running   0          3m
kyverno-background-controller-6c5b7f9d8-fghij    1/1     Running   0          3m
kyverno-cleanup-controller-5f6d8b7c9-klmno       1/1     Running   0          3m
kyverno-reports-controller-8b7c6d5f4-pqrst       1/1     Running   0          3m
```

Si falta algún controlador, el escaneo en background y los Policy Reports no funcionarán y varios ejercicios de abajo fallarán en silencio — lo cual es en sí mismo una lección de por qué se verifica el plano de control antes de confiar en la salida de las políticas.

```bash
# 2. Create a scratch namespace and export the Kyverno version for reference.
kubectl create namespace policy-lab
kubectl get deploy -n kyverno kyverno-admission-controller \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

---

### Ejercicio 1 — `validationFailureAction`: Audit vs Enforce

**Objetivo:** Comprobar por vos mismo que la *misma* regla o bien bloquea o bien solo reporta, controlado por un único campo, y localizar dónde se registra una violación no bloqueante.

1. Creá una política en modo **Audit** que requiera una etiqueta `team` en cada Pod.

```yaml
# require-team-audit.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-team-label
spec:
  validationFailureAction: Audit
  background: true
  rules:
    - name: check-team-label
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "Every Pod must carry a 'team' label."
        pattern:
          metadata:
            labels:
              team: "?*"
```

```bash
kubectl apply -f require-team-audit.yaml
kubectl get cpol require-team-label
```

Esperado (las columnas varían ligeramente según la versión):

```
NAME                 ADMISSION   BACKGROUND   READY   AGE   MESSAGE
require-team-label   true        true         True    8s    Ready
```

2. Creá un Pod que **viole** la regla y observá que se admite igualmente.

```yaml
# nginx-nolabel.yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx-nolabel
  namespace: policy-lab
spec:
  containers:
    - name: nginx
      image: nginx:1.27
```

```bash
kubectl apply -f nginx-nolabel.yaml
# pod/nginx-nolabel created
```

3. Encontrá dónde se registró la violación — no bloqueó, pero *no* fue ignorada.

```bash
kubectl get policyreports -n policy-lab
kubectl describe polr -n policy-lab <report-name-from-above>
```

Esperado (los nombres de los reportes se autogeneran y dependen de la versión; leé las columnas, no el nombre):

```
NAMESPACE    NAME                              PASS   FAIL   WARN   ERROR   SKIP   AGE
policy-lab   6a9c1f7e-2b3d-4e5f-report         0      1      0      0       0      12s
```

La salida de `describe` muestra `result: fail`, la política/regla, y el recurso infractor.

4. Ahora cambiá la política a **Enforce** y reintentá con un nuevo Pod infractor.

```bash
kubectl patch cpol require-team-label --type merge \
  -p '{"spec":{"validationFailureAction":"Enforce"}}'

kubectl run nginx-blocked --image=nginx:1.27 -n policy-lab
```

Esperado:

```
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/policy-lab/nginx-blocked was blocked due to the following policies

require-team-label:
  check-team-label: 'validation error: Every Pod must carry a ''team'' label.
    rule check-team-label failed at path /metadata/labels/team/'
```

**Verificá tu comprensión**

1. Bajo `Audit`, el Pod infractor se creó. ¿A dónde fue la violación, y qué controlador de Kyverno produjo ese registro?
2. Cambiaste `validationFailureAction` de `Audit` a `Enforce`. ¿El Pod `nginx-nolabel` *ya creado* fue eliminado o bloqueado retroactivamente? ¿Por qué sí o por qué no?
3. En el mensaje de error de Enforce, ¿qué te dice el sufijo `-fail` del webhook en `validate.kyverno.svc-fail` sobre un ajuste común de política *distinto*?
4. ¿Por qué `Audit` es el primer paso recomendado al desplegar una política nueva en un cluster existente?

---

### Ejercicio 2 — `validationFailureActionOverrides`: mezclar la aplicación por namespace

**Objetivo:** Aplicar globalmente mientras se eximen namespaces específicos (p. ej. dev/sandbox) sin mantener dos copias de la misma política.

1. Reemplazá la política por una que aplique en todos lados **excepto** en los namespaces que coincidan con `dev-*` y el literal `sandbox`, donde solo audita.

```yaml
# require-team-overrides.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-team-label
spec:
  validationFailureAction: Enforce
  validationFailureActionOverrides:
    - action: Audit
      namespaces:
        - "dev-*"
        - "sandbox"
  background: true
  rules:
    - name: check-team-label
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "Every Pod must carry a 'team' label."
        pattern:
          metadata:
            labels:
              team: "?*"
```

```bash
kubectl apply -f require-team-overrides.yaml
kubectl create namespace dev-alice
```

2. Mostrá los dos comportamientos uno al lado del otro.

```bash
# Blocked in policy-lab (Enforce applies):
kubectl run t1 --image=nginx:1.27 -n policy-lab
# Error from server: ... was blocked due to the following policies ...

# Admitted in dev-alice (Audit override applies):
kubectl run t2 --image=nginx:1.27 -n dev-alice
# pod/t2 created
```

**Verificá tu comprensión**

1. ¿Por qué `validationFailureActionOverrides` solo tiene sentido en una `ClusterPolicy` y no en una `Policy` con namespace?
2. La lista de overrides hizo coincidir `dev-alice` con `dev-*`. ¿Qué mecanismo de coincidencia usa el campo `namespaces` — regex, glob/comodín, o cadena exacta?
3. Si un namespace coincidiera con *dos* entradas de override con acciones en conflicto, ¿cuál gana? (Pista: pensá en el orden de la lista.)
4. Tu equipo quiere "Enforce en prod, Audit en todo lo demás". ¿Es más limpio listar los namespaces auditados, o invertir la lógica? ¿Qué riesgo operativo conlleva el enfoque de "listar las excepciones" a medida que aparecen nuevos namespaces?

---

### Ejercicio 3 — `background` y la restricción de variables solo de admisión

**Objetivo:** Entender qué es el escaneo en background, qué no puede ver, y por qué Kyverno *rechaza* ciertas políticas a menos que lo desactives.

1. Confirmá que el escaneo en background está poblando reportes para un recurso **preexistente**. El Pod `nginx-nolabel` del Ejercicio 1 ya existe y viola la política Enforce actual — el escaneo en background lo reporta sin ninguna nueva solicitud de admisión.

```bash
kubectl get polr -n policy-lab
# The FAIL column reflects the standing violation of nginx-nolabel,
# produced by the background/reports controller, not by an admission event.
```

2. Ahora intentá crear una política que use una variable de contexto **solo de admisión** dejando `background: true` (el valor por defecto).

```yaml
# block-self-approval.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: block-self-updates
spec:
  # background left at its default (true) on purpose — this should FAIL.
  rules:
    - name: deny-kube-system-user
      match:
        any:
          - resources:
              kinds:
                - ConfigMap
      validate:
        message: "system:masters may not edit ConfigMaps directly."
        deny:
          conditions:
            any:
              - key: "{{ request.userInfo.groups }}"
                operator: AnyIn
                value:
                  - "system:masters"
```

```bash
kubectl apply -f block-self-approval.yaml
```

Esperado — la política es rechazada en la admisión:

```
Error from server: admission webhook "validate-policy.kyverno.svc-fail" denied the request:
spec.rules[0]: policy uses variables that are only available during admission
(request.userInfo). Set spec.background to false.
```

3. Arreglalo desactivando background para esta política, luego re-aplicá.

```bash
# Add `background: false` under spec, then:
kubectl apply -f block-self-approval.yaml
kubectl get cpol block-self-updates
```

Esperado:

```
NAME                  ADMISSION   BACKGROUND   READY   AGE   MESSAGE
block-self-updates    true        false        True    5s    Ready
```

**Verificá tu comprensión**

1. Nombrá tres datos que existen *solo* durante un AdmissionReview y que por lo tanto no pueden evaluarse durante un escaneo en background.
2. Se crea una política con `background: false`. ¿Sigue bloqueando solicitudes infractoras en el momento de la admisión? ¿Qué deja de hacer?
3. ¿Por qué Kyverno rechaza la política en el momento de su creación en lugar de saltarse silenciosamente la regla afectada durante los escaneos en background?
4. Tenés una política Audit y querés que sus violaciones aparezcan en los Policy Reports para recursos que ya existen. ¿Qué ajuste debe estar en `true`, y qué controlador hace el trabajo real?

---

### Ejercicio 4 — `failurePolicy`: fail-closed vs fail-open

**Objetivo:** Ver cómo un único ajuste decide si el cluster sigue admitiendo recursos cuando Kyverno está *caído*, e inspeccionar el webhook que genera.

1. Inspeccioná la configuración del webhook autogenerado y correlacioná su `failurePolicy` con el valor por defecto de tu política.

```bash
kubectl get validatingwebhookconfigurations | grep kyverno
kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg \
  -o jsonpath='{range .webhooks[*]}{.name}{"\t"}{.failurePolicy}{"\n"}{end}'
```

Esperado (fijate en los sufijos `-fail` / `-ignore` — Kyverno separa las políticas Fail e Ignore en entradas de webhook distintas):

```
validate.kyverno.svc-fail       Fail
validate.kyverno.svc-ignore     Ignore
```

2. Creá una política fail-open explícitamente y confirmá en qué entrada de webhook cae.

```yaml
# require-team-failopen.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-team-failopen
spec:
  validationFailureAction: Enforce
  failurePolicy: Ignore
  background: true
  rules:
    - name: check-team-label
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "Every Pod must carry a 'team' label."
        pattern:
          metadata:
            labels:
              team: "?*"
```

```bash
kubectl apply -f require-team-failopen.yaml
```

3. Simulá que Kyverno no está disponible y observá la diferencia. Escalá el controlador de admisión a cero, luego creá Pods gobernados por una política `Fail` y por una política `Ignore`.

```bash
kubectl scale deploy -n kyverno kyverno-admission-controller --replicas=0
sleep 15

# Governed by require-team-label (failurePolicy: Fail, the default):
kubectl run fp-test --image=nginx:1.27 -n policy-lab
# Error from server: Internal error occurred: failed calling webhook
# "validate.kyverno.svc-fail": ... connection refused
```

4. Restaurá el controlador.

```bash
kubectl scale deploy -n kyverno kyverno-admission-controller --replicas=1
```

**Verificá tu comprensión**

1. Enunciá el comportamiento exacto de `failurePolicy: Fail` y `failurePolicy: Ignore` cuando el endpoint del webhook de Kyverno es inalcanzable.
2. ¿Qué valor es el valor por defecto seguro ("fail-closed"), y cuál es el peligro operativo concreto de ejecutarlo durante una caída de Kyverno?
3. Viste dos entradas de webhook, `...svc-fail` y `...svc-ignore`. ¿Por qué Kyverno separa las políticas en dos configuraciones de webhook en lugar de una sola?
4. Para una política que *muta* Pods para inyectar un security context requerido, ¿preferirías `Fail` o `Ignore`? Justificá el compromiso entre seguridad y disponibilidad para ese caso específico.

---

### Ejercicio 5 — `applyRules`: All vs One

**Objetivo:** Controlar si se disparan todas las reglas coincidentes de una política, o solo la primera — crítico para reglas mutate ordenadas.

1. Creá una política con dos reglas mutate y el valor por defecto `applyRules: All`.

```yaml
# tier-labels-all.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-tier-labels
spec:
  applyRules: All          # default; both rules will apply
  background: false
  rules:
    - name: add-tier-backend
      match:
        any:
          - resources:
              kinds:
                - Pod
              selector:
                matchLabels:
                  app: api
      mutate:
        patchStrategicMerge:
          metadata:
            labels:
              tier: backend
    - name: add-tier-general
      match:
        any:
          - resources:
              kinds:
                - Pod
      mutate:
        patchStrategicMerge:
          metadata:
            labels:
              tier: general
```

```bash
kubectl apply -f tier-labels-all.yaml
kubectl run api-pod --image=nginx:1.27 -n policy-lab -l app=api --dry-run=server -o yaml \
  | grep -A3 'labels:'
```

Con `applyRules: All`, la segunda regla se ejecuta después de la primera y gana la última escritura → `tier: general`.

2. Cambiá a `applyRules: One` para que la evaluación se detenga en la primera regla coincidente.

```bash
kubectl patch cpol add-tier-labels --type merge -p '{"spec":{"applyRules":"One"}}'
kubectl run api-pod2 --image=nginx:1.27 -n policy-lab -l app=api --dry-run=server -o yaml \
  | grep -A3 'labels:'
```

Ahora solo se dispara `add-tier-backend` → `tier: backend`, y la evaluación se detiene.

**Verificá tu comprensión**

1. Con `applyRules: All`, ambas reglas mutate coincidieron con el Pod `app: api`. ¿Qué valor terminó en la etiqueta `tier`, y por qué?
2. ¿Cuál es la razón más común para poner `applyRules: One`?
3. ¿`applyRules: One` cambia *cuál* regla se considera "la primera"? ¿Qué determina el orden de las reglas dentro de una política?
4. ¿Sería apropiado `applyRules: One` para una política que contiene múltiples reglas `validate` independientes que cada una verifica un requisito distinto? Explicá el riesgo.

---

### Ejercicio 6 — `webhookTimeoutSeconds` y la lectura del webhook generado

**Objetivo:** Ajustar cuánto tiempo espera el API server a Kyverno antes de aplicar el `failurePolicy`, y ver el ajuste propagarse a la configuración del webhook en vivo.

1. Establecé un timeout explícito en una política.

```yaml
# timeout-demo.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: timeout-demo
spec:
  validationFailureAction: Audit
  webhookTimeoutSeconds: 15
  background: true
  rules:
    - name: require-runasnonroot
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "Containers must set securityContext.runAsNonRoot: true."
        pattern:
          spec:
            containers:
              - securityContext:
                  runAsNonRoot: true
```

```bash
kubectl apply -f timeout-demo.yaml
```

2. Leé el timeout de vuelta desde la configuración del webhook que Kyverno mantiene.

```bash
kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg \
  -o jsonpath='{range .webhooks[*]}{.name}{"\t"}{.timeoutSeconds}{"\n"}{end}'
```

Esperado:

```
validate.kyverno.svc-fail       15
validate.kyverno.svc-ignore     15
```

**Verificá tu comprensión**

1. ¿Cuál es el rango permitido para `webhookTimeoutSeconds`, y cuál es el valor por defecto si lo omitís?
2. Cuando se excede el timeout, lo que ocurre a continuación depende de *otro* ajuste común — ¿cuál, y cuáles son los dos posibles resultados?
3. ¿Por qué un timeout de webhook muy alto en una política `Fail` es operativamente peligroso para todo el API server, no solo para Kyverno?
4. Kyverno registra webhooks *solo* para los tipos de recurso que al menos una política tiene como objetivo. ¿Por qué es importante ese acotamiento para la latencia del API server y el radio de impacto?

---

### Limpieza

```bash
kubectl delete cpol require-team-label require-team-failopen block-self-updates \
  add-tier-labels timeout-demo --ignore-not-found
kubectl delete namespace policy-lab dev-alice sandbox --ignore-not-found
```

---

## Respuestas

<details>
<summary>Hacé clic para revelar las respuestas y su fundamento</summary>

### Ejercicio 1 — `validationFailureAction`

1. La violación se escribió en un **Policy Report** (`PolicyReport`/`polr` en el namespace del recurso) con `result: fail`. El **reports controller** agrega la evaluación en tiempo de admisión (y los resultados del escaneo en background) en estos objetos report `wgpolicyk8s.io/v1alpha2`. Bajo `Audit`, el controlador de admisión permite la solicitud pero igualmente emite el resultado de la evaluación.
2. Ninguno de los dos. `Enforce` solo afecta a solicitudes de admisión **nuevas o actualizadas**. El webhook de validación de Kyverno intercepta `CREATE`/`UPDATE`/`CONNECT`, no los recursos en reposo, por lo que un Pod ya admitido nunca es bloqueado ni eliminado retroactivamente. Su violación en pie, sin embargo, aparecerá en los Policy Reports vía el escaneo en background.
3. El sufijo `-fail` es el nombre de la entrada de webhook para políticas cuyo `failurePolicy` es `Fail` (el valor por defecto). Kyverno agrupa las políticas `Fail` e `Ignore` en configuraciones de webhook separadas (`...svc-fail` / `...svc-ignore`) — así que el mensaje ya revela el `failurePolicy` efectivo (Ejercicio 4).
4. `Audit` te permite medir el impacto real — cuántos recursos existentes y entrantes serían bloqueados — sin romper ninguna carga de trabajo ni pipelines de CI/CD. Promovés a `Enforce` solo después de que el conteo de reportes para recursos legítimos llegue a cero. Ir directo a `Enforce` en un cluster poblado corre el riesgo de bloquear despliegues en todo el cluster.

### Ejercicio 2 — `validationFailureActionOverrides`

1. Los overrides clavan recursos por `namespaces`, y una `Policy` con namespace ya vive en — y solo aplica a — un único namespace, así que no hay nada que anular entre namespaces. El campo solo tiene sentido para una `ClusterPolicy` con alcance de cluster.
2. Usa coincidencia **glob/comodín** (p. ej. `dev-*`), no expresiones regulares completas ni cadenas solo-exactas. `dev-alice` coincide con `dev-*`.
3. Gana la **primera entrada coincidente en el orden de la lista**. Ordená tus overrides de más específico a menos específico para obtener un comportamiento determinista.
4. Listar las excepciones auditadas (`Enforce` globalmente, anulando namespaces específicos a `Audit`) es común pero conlleva un **riesgo de deriva fail-open**: cualquier namespace *nuevo* que olvides agregar hereda `Enforce`, que es la dirección segura — pero si en cambio lo invertís (Audit globalmente, Enforce solo en los namespaces de prod listados), un nuevo namespace de prod silenciosamente recibe solo `Audit`. Preferí el arreglo donde "me olvidé de actualizar la lista" falla hacia *más* aplicación, no menos.

### Ejercicio 3 — `background`

1. Cualquier dato solo del AdmissionReview: `request.userInfo` (usuario/grupos), `request.roles` / `request.clusterRoles`, la operación (`request.operation`), el `oldObject` del objeto solicitante en las actualizaciones, y datos de imagen/registry solo disponibles en tiempo de admisión. Ninguno de estos existe cuando el reports controller re-escanea un recurso en reposo.
2. Sí — `background: false` desactiva solo el **escaneo en background** (la re-evaluación periódica de recursos existentes y la generación de reportes para ellos). La política sigue ejecutándose en **admisión** y sigue bloqueando/mutando las solicitudes en vivo normalmente.
3. Saltárselo silenciosamente haría que la cobertura de la política fuera invisible y no determinista — un control de seguridad que "a veces no aplica" es peor que uno que falla ruidosamente. Kyverno rechaza la política en su creación para que el autor reconozca explícitamente el compromiso poniendo `background: false`.
4. `background` debe estar en `true` (el valor por defecto). El **background controller** re-evalúa los recursos existentes en el intervalo del escaneo en background, y el **reports controller** agrega los resultados en los Policy Reports.

### Ejercicio 4 — `failurePolicy`

1. `Fail` (fail-closed): si el webhook es inalcanzable o da error, el API server **rechaza** la solicitud. `Ignore` (fail-open): el API server **permite** que la solicitud proceda como si no existiera ninguna política.
2. `Fail` es el valor por defecto seguro. Su peligro: si el controlador de admisión de Kyverno está caído (crash, upgrade, partición de red), *toda* solicitud `CREATE`/`UPDATE` para los tipos de recurso que gobierna se bloquea — lo que puede detener Deployments, impedir la reprogramación de Pods durante un fallo de nodo, y, en el peor caso, impedir que arregles el propio Kyverno.
3. El `ValidatingWebhookConfiguration` del API server fija `failurePolicy` por entrada de webhook, no por política. Kyverno, por lo tanto, coloca todas las políticas `Fail` bajo una entrada de webhook (`...svc-fail`) y todas las políticas `Ignore` bajo otra (`...svc-ignore`) para que cada grupo obtenga el comportamiento de fallo correcto del API server.
4. Para una inyección de security-context *mutante*, muchos equipos igual eligen `Fail`: si la mutación no puede ejecutarse, no querés que se admita un Pod sin endurecer. Pero eso debe sopesarse contra la disponibilidad — un webhook de mutación que es fail-closed y lento/caído bloquea toda la creación de Pods. La respuesta defendible enuncia el compromiso explícitamente: `Fail` para una garantía de seguridad fuerte a costa de la disponibilidad durante las caídas de Kyverno; `Ignore` para disponibilidad a costa de una brecha de endurecimiento. No hay una respuesta universalmente correcta — depende de si el control es un requisito de cumplimiento o un valor por defecto de mejor esfuerzo.

### Ejercicio 5 — `applyRules`

1. `tier: general`. Con `applyRules: All`, ambas reglas mutate se dispararon en orden; la regla posterior (`add-tier-general`) parcheó la etiqueta última, por lo que ganó su valor (la última escritura gana para el strategic merge sobre la misma clave).
2. Para hacer determinista la **mutación ordenada** — aplicar solo la primera regla cuyo `match` tenga éxito y detenerse, de modo que las reglas más específicas listadas antes tengan precedencia sobre los fallbacks generales y las reglas posteriores no puedan sobrescribirlas.
3. No — no reordena nada. "La primera" significa la primera regla en la lista `rules` de la política (orden del documento) cuyo `match`/`exclude` selecciona el recurso. El ordenamiento es responsabilidad del autor.
4. No. Para reglas `validate` independientes, `applyRules: One` se detendría tras la primera regla coincidente, por lo que los requisitos restantes **nunca se verificarían** — un recurso podría pasar la validación violando las reglas 2..N. `One` está pensado para la precedencia de mutate, no para cortocircuitar validaciones independientes.

### Ejercicio 6 — `webhookTimeoutSeconds`

1. Rango **1–30 segundos**; el valor por defecto es **10**.
2. `failurePolicy`. En un timeout, el API server trata la llamada al webhook como fallida, así que `Fail` → la solicitud es rechazada, `Ignore` → la solicitud es admitida sin la política.
3. Un timeout alto en una política `Fail` significa que cada solicitud gobernada puede colgarse hasta esa cantidad de segundos esperando a Kyverno antes de que el API server se rinda. Si Kyverno está lento o sobrecargado, esto multiplica la latencia a través de todas las admisiones coincidentes y puede degradar el throughput de solicitudes del API server en todo el cluster — el timeout es un techo de cuánto tiempo puede estancarse *toda la cadena de admisión*.
4. Acotar los webhooks solo a los tipos de recurso bajo política significa que el API server no llama a Kyverno para objetos no relacionados. Eso reduce la latencia de admisión agregada y encoge el radio de impacto: una caída de Kyverno con `Fail` solo afecta a los tipos específicos que efectivamente gobernás, no a cada escritura en el cluster.

</details>

---

## Fuentes

- Kyverno — Policy Settings (applyRules, admission, background, failurePolicy, generateExisting, mutateExistingOnPolicyUpdate, schemaValidation, validationFailureAction, validationFailureActionOverrides, webhookTimeoutSeconds): https://kyverno.io/docs/writing-policies/policy-settings/
- Kyverno — Validate rules and `validationFailureAction`: https://kyverno.io/docs/writing-policies/validate/
- Kyverno — Policy Reports (background scanning, `polr`/`cpolr`): https://kyverno.io/docs/policy-reports/
- Kyverno — Mutate rules and `applyRules` ordering: https://kyverno.io/docs/writing-policies/mutate/
- Kubernetes — Dynamic Admission Control (`failurePolicy`, `timeoutSeconds`, matchConditions): https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/