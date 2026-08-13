# KCA — Tema 3.2: `kyverno test`

**Dominio 3 — Kyverno CLI · Peso en el examen: 3.0%**

Ejercicios guiados. Cada paso se ejecuta en tu estación de trabajo; **no se requiere ningún cluster de Kubernetes ni kubeconfig en ningún momento**. Esa es la propiedad que define a `kyverno test`: es un ejecutor de aserciones offline, determinista y dirigido por códigos de salida para políticas de Kyverno — la misma clase de herramienta que `go test` o `helm unittest`, no una operación sobre el cluster.

> **Deriva de versiones.** Estos ejercicios apuntan a la CLI de Kyverno **1.13.x** (manifiestos `Test` en `cli.kyverno.io/v1alpha1`). Los encabezados de columna y el texto de los logs en la salida de la CLI cambiaron levemente entre 1.10 → 1.14; tratá los bloques impresos abajo como formas representativas, y confirmá los flags para *tu* binario con `kyverno test --help`. Cuando un campo o apiVersion cambió entre releases, se aclara en línea.

---

## Ejercicio 0 — Preparar el laboratorio offline

1. Instalá la CLI (elegí una):

```bash
# Option A — krew
kubectl krew install kyverno

# Option B — release tarball (pin the version you intend to certify against)
VERSION=$(curl -s https://api.github.com/repos/kyverno/kyverno/releases/latest | grep -oP '"tag_name": "\K[^"]+')
curl -sLO "https://github.com/kyverno/kyverno/releases/download/${VERSION}/kyverno-cli_${VERSION}_linux_x86_64.tar.gz"
tar -xzf "kyverno-cli_${VERSION}_linux_x86_64.tar.gz" kyverno
sudo install -m 0755 kyverno /usr/local/bin/kyverno

# Option C — Homebrew
brew install kyverno
```

2. Confirmá el binario y registrá la versión — el entorno del examen fija una:

```bash
kyverno version
```

```
Version: 1.13.4
Time: 2025-02-19T10:41:22Z
Git commit ID: 9f2a1c3b...
```

3. Demostrá que el subcomando es independiente del cluster rompiendo tu kubeconfig para la shell:

```bash
export KUBECONFIG=/nonexistent
kyverno test --help
```

```
Usage:
  kyverno test [local folder or git repository]... [flags]

Flags:
      --detailed-results          If passed, display detailed results
      --fail-only                 If set, display all resources of failed policies only
  -f, --file-name string          Test filename (default "kyverno-test.yaml")
  -b, --git-branch string         test git repository branch
  -h, --help                      help for test
      --registry                  If set to true, access the image registry using local docker credentials
      --remove-color              Remove any color from output
  -t, --test-case-selector string run some specific test cases (default "policy=*,rule=*,resource=*")
```

4. Creá el árbol del laboratorio:

```bash
mkdir -p ~/kca-3.2-lab/require-labels && cd ~/kca-3.2-lab/require-labels
```

**Preguntas**

- **Q1.** `kyverno test --help` imprimió normalmente con `KUBECONFIG=/nonexistent`. ¿Qué te dice eso sobre dónde corre el motor de políticas, y qué consecuencia práctica tiene para los pipelines de CI?
- **Q2.** ¿Qué único flag en la salida de ayuda introduce una dependencia de red externa, y por qué importa para un pipeline hermético?
- **Q3.** La línea de uso acepta *"local folder or git repository"*. ¿Qué archivo busca la CLI cuando le pasás una carpeta?

---

## Ejercicio 1 — Anatomía de un manifiesto `Test`: la primera corrida en verde

1. Escribí la política bajo prueba, `policy.yaml`:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-labels
spec:
  validationFailureAction: Enforce   # 1.12+ also supports per-rule spec.rules[].validate.failureAction
  background: true
  rules:
    - name: check-for-labels
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "The label `app.kubernetes.io/name` is required."
        pattern:
          metadata:
            labels:
              app.kubernetes.io/name: "?*"
```

2. Escribí los fixtures, `resources.yaml` — uno conforme, uno no:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-with-label
  namespace: default
  labels:
    app.kubernetes.io/name: nginx
spec:
  containers:
    - name: nginx
      image: nginx:1.27.4
---
apiVersion: v1
kind: Pod
metadata:
  name: pod-without-label
  namespace: default
spec:
  containers:
    - name: nginx
      image: nginx:1.27.4
```

3. Escribí la declaración de prueba, `kyverno-test.yaml`:

```yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: require-labels
policies:
  - policy.yaml
resources:
  - resources.yaml
results:
  - policy: require-labels
    rule: check-for-labels
    kind: Pod
    resources:
      - pod-with-label
    result: pass
  - policy: require-labels
    rule: check-for-labels
    kind: Pod
    resources:
      - pod-without-label
    result: fail
```

4. Corré la prueba e inspeccioná el código de salida:

```bash
kyverno test .
echo "exit=$?"
```

```
Loading test  ( ./kyverno-test.yaml ) ...
  Loading values/variables ...
  Loading policies ...
  Loading resources ...
  Applying 1 policy to 2 resources ...
  Checking results ...

│────│────────────────│──────────────────│──────────────────────────────────│────────│
│ ID │ POLICY         │ RULE             │ RESOURCE                         │ RESULT │
│────│────────────────│──────────────────│──────────────────────────────────│────────│
│ 1  │ require-labels │ check-for-labels │ v1/Pod/default/pod-with-label    │ Pass   │
│ 2  │ require-labels │ check-for-labels │ v1/Pod/default/pod-without-label │ Pass   │
│────│────────────────│──────────────────│──────────────────────────────────│────────│

Test Summary: 2 tests passed and 0 tests failed

exit=0
```

**Preguntas**

- **Q4.** La fila 2 asevera `result: fail`, sin embargo la columna `RESULT` imprime `Pass`. Explicá con precisión qué mide la columna `RESULT`. ¿Por qué confundir estas dos es la lectura errónea más común de la salida de `kyverno test`?
- **Q5.** `policies:` y `resources:` contienen `policy.yaml` y `resources.yaml`. ¿Relativo a qué directorio se resuelven esas rutas — el CWD de tu shell, o algo más? Demostralo corriendo `kyverno test ~/kca-3.2-lab/require-labels` desde `/tmp`.
- **Q6.** `results[].resources` es una lista. ¿Qué te permite expresar que una entrada por recurso no puede, y cuál es el campo singular más viejo, ahora deprecado, que reemplazó?
- **Q7.** Borraste `rule: check-for-labels` de ambas entradas de result. ¿Seguiría siendo la prueba una aserción válida? ¿Cuál es el riesgo de omitirlo en una política multi-regla?

---

## Ejercicio 2 — Leer una falla real, y los flags que acortan la lectura

1. Rompé la expectativa deliberadamente — cambiá la segunda entrada a `pass`:

```bash
sed -i '0,/result: fail/! s/result: fail/result: pass/' kyverno-test.yaml
grep -n "result:" kyverno-test.yaml
```

2. Volvé a correr y capturá el código de salida:

```bash
kyverno test . ; echo "exit=$?"
```

```
│────│────────────────│──────────────────│──────────────────────────────────│────────│
│ ID │ POLICY         │ RULE             │ RESOURCE                         │ RESULT │
│────│────────────────│──────────────────│──────────────────────────────────│────────│
│ 1  │ require-labels │ check-for-labels │ v1/Pod/default/pod-with-label    │ Pass   │
│ 2  │ require-labels │ check-for-labels │ v1/Pod/default/pod-without-label │ Fail   │
│────│────────────────│──────────────────│──────────────────────────────────│────────│

Test Summary: 1 tests passed and 1 tests failed

exit=1
```

3. Pedí la razón y solo las fallas:

```bash
kyverno test . --detailed-results
kyverno test . --fail-only
```

La tabla detallada agrega una columna `REASON` que lleva el desajuste de expectativa (`Want pass, got fail`) y el mensaje de validación de la regla.

4. Producí salida segura para un colector de logs:

```bash
kyverno test . --remove-color --detailed-results 2>&1 | tee /tmp/kca-test.log
echo "exit=${PIPESTATUS[0]}"
```

5. Restaurá la expectativa correcta antes de continuar:

```bash
sed -i '0,/result: pass/! s/result: pass/result: fail/' kyverno-test.yaml
kyverno test . && echo "green"
```

**Preguntas**

- **Q8.** El paso 4 lee `${PIPESTATUS[0]}` en vez de `$?`. ¿Qué modo de falla de los pipelines de CI evita eso?
- **Q9.** Tu pipeline corre `kyverno test ./policies/` sobre 200 políticas y una aserción regresiona. ¿Qué dos flags agregás para hacer accionable el log de CI, y qué aporta cada uno?
- **Q10.** Un colega propone controlar el pipeline con `grep -q "0 tests failed"` en vez del código de salida. Da dos razones por las que ese es un peor gate.

---

## Ejercicio 3 — El vocabulario de result: `pass`, `fail`, `skip`, `error`

El campo `result` no es texto libre. Es un resultado de policy-report, y elegir el equivocado es un bug de la prueba incluso cuando la política es correcta.

1. Agregá una segunda regla, condicionada por precondition, a `policy.yaml`:

```yaml
    - name: backend-needs-owner
      match:
        any:
          - resources:
              kinds:
                - Pod
      preconditions:
        all:
          - key: "{{ request.object.metadata.labels.tier || '' }}"
            operator: Equals
            value: backend
      validate:
        message: "Backend Pods must carry the annotation corp.io/owner."
        pattern:
          metadata:
            annotations:
              corp.io/owner: "?*"
```

2. Agregá una tercera regla que referencia una variable **sin** fallback:

```yaml
    - name: owner-must-be-a-team
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "corp.io/owner must end in -team."
        deny:
          conditions:
            all:
              - key: "{{ request.object.metadata.annotations.\"corp.io/owner\" }}"
                operator: NotEquals
                value: "*-team"
```

3. Extendé `kyverno-test.yaml` con expectativas para ambas reglas nuevas contra `pod-with-label` (que no tiene ni `tier: backend` ni la annotation):

```yaml
  - policy: require-labels
    rule: backend-needs-owner
    kind: Pod
    resources:
      - pod-with-label
    result: skip
  - policy: require-labels
    rule: owner-must-be-a-team
    kind: Pod
    resources:
      - pod-with-label
    result: error
```

4. Corré y confirmá que ambas filas imprimen `Pass`:

```bash
kyverno test . --detailed-results
```

5. Ahora dale a `pod-with-label` la label `tier: backend` en `resources.yaml`, dejá la annotation ausente, volvé a correr, y observá cómo la expectativa de `backend-needs-owner` debe cambiar.

**Preguntas**

- **Q11.** Distinguí `skip` de `fail` en una oración cada uno, en términos de lo que el motor realmente hizo.
- **Q12.** La regla `owner-must-be-a-team` produce `error`, no `fail`, para un Pod sin esa annotation. ¿Qué pasó dentro del motor, y qué única edición a la regla convierte el `error` en un `pass`/`fail` determinista?
- **Q13.** ¿Por qué una regla que produce `error` en la CLI es un incidente de producción esperando a suceder, dada una política con `validationFailureAction: Enforce`? Considerá el `failurePolicy` de Kyverno en el admission webhook.
- **Q14.** Después del paso 5, ¿cuál es la expectativa correcta para `backend-needs-owner` contra `pod-with-label`, y por qué?
- **Q15.** ¿Cambiar `validationFailureAction` de `Enforce` a `Audit` cambia el valor de `result` que debés escribir en la prueba? Justificá.

---

## Ejercicio 4 — Reglas autogeneradas: la trampa de autogen

Kyverno autogenera variantes de controlador de Pod para las reglas de Pod. Esas variantes tienen **nombres de regla diferentes**, y la prueba debe referenciar el nombre generado.

1. Agregá un fixture de Deployment a `resources.yaml`:

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: deploy-without-label
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
        - name: nginx
          image: nginx:1.27.4
```

2. Agregá la expectativa *ingenua* y mirá cómo falla:

```yaml
  - policy: require-labels
    rule: check-for-labels
    kind: Deployment
    resources:
      - deploy-without-label
    result: fail
```

```bash
kyverno test . --detailed-results
```

```
│ 5  │ require-labels │ check-for-labels │ apps/v1/Deployment/default/deploy-without-label │ Fail │ Not found │
Test Summary: 4 tests passed and 1 tests failed
```

3. Arreglalo nombrando la regla autogenerada:

```yaml
    rule: autogen-check-for-labels
```

4. Volvé a correr; la fila ahora pasa. Inspeccioná lo que Kyverno realmente generó:

```bash
kyverno apply policy.yaml --resource resources.yaml --policy-report | head -40
```

**Preguntas**

- **Q16.** Para una regla llamada `check-for-labels` que matchea `Pod`, ¿qué nombres de regla produce autogen para un `Deployment` y para un `CronJob`?
- **Q17.** La razón de la falla fue `Not found` en vez de un desajuste de result. ¿Qué significa esa razón, y nombrá las tres causas más comunes.
- **Q18.** ¿Qué annotation en la política controla el comportamiento de autogen, y qué valor lo deshabilita por completo? ¿Qué le haría eso a las expectativas que acabás de escribir?
- **Q19.** Tu política matchea solo `Pod`, sin embargo se ejercita un fixture de `Deployment`. ¿Por qué probar la variante de controlador — no solo el Pod desnudo — es innegociable para una política de producción?

---

## Ejercicio 5 — Variables, `globalValues` e información de usuario

Las políticas que referencian `request.operation`, `request.userInfo`, labels de namespace, o contexto externo no pueden evaluarse solo desde el manifiesto del recurso. El archivo `variables:` los provee.

1. Creá `values.yaml`:

```yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Value
metadata:
  name: values
spec:
  globalValues:
    request.operation: CREATE
  namespaceSelector:
    - name: default
      labels:
        env: sandbox
  policies:
    - name: require-labels
      resources:
        - name: pod-with-label
          values:
            corp.io/costcenter: "cc-4471"
```

2. Referencialo desde el manifiesto de prueba:

```yaml
variables: values.yaml
```

3. Creá `userinfo.yaml` para reglas que dependen de la identidad solicitante:

```yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: UserInfo
metadata:
  name: user-info
clusterRoles:
  - cluster-admin
userInfo:
  username: sre@corp.io
  groups:
    - system:authenticated
    - platform-sre
```

4. Referencialo también, y volvé a correr:

```yaml
userinfo: userinfo.yaml
```

```bash
kyverno test . --detailed-results
```

5. Cambiá `request.operation` a `UPDATE` en `globalValues` y volvé a correr. Notá qué filas cambian.

**Preguntas**

- **Q20.** ¿Cuál es el valor por defecto de `request.operation` cuando no se provee archivo de variables, y por qué ese valor por defecto deja algunas reglas sin probar silenciosamente?
- **Q21.** Distinguí `spec.globalValues` de `spec.policies[].resources[].values`. ¿Cuándo la forma por recurso es obligatoria en vez de meramente prolija?
- **Q22.** Tu política usa `preconditions` sobre `{{ request.userInfo.groups }}`. Corrés la prueba sin un archivo `userinfo:`. ¿Cuál de `pass`/`fail`/`skip`/`error` esperás, y por qué?
- **Q23.** `namespaceSelector` en el archivo de values provee labels para un namespace que no existe en `resources:`. ¿Por qué la CLI necesita esto, y qué comportamiento de Kyverno en runtime está emulando?
- **Q24.** Una regla llama a una entrada de contexto APICall contra el cluster en vivo. ¿Puede `kyverno test` evaluarla fielmente? ¿Cuál es la forma soportada de probar tal regla offline?

---

## Ejercicio 6 — Reglas mutate: `patchedResource`, generado no escrito a mano

1. Nuevo directorio y política, `~/kca-3.2-lab/add-owner/policy.yaml`:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-owner-annotation
spec:
  rules:
    - name: add-annotation
      match:
        any:
          - resources:
              kinds:
                - Pod
      mutate:
        patchStrategicMerge:
          metadata:
            annotations:
              corp.io/owner: platform-team
```

2. Fixture `resource.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-unowned
  namespace: default
spec:
  containers:
    - name: nginx
      image: nginx:1.27.4
```

3. **Generá** la salida esperada en vez de escribirla:

```bash
mkdir -p patched
kyverno apply policy.yaml --resource resource.yaml -o patched/
cat patched/*.yaml
```

4. Conectala en `kyverno-test.yaml`:

```yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: add-owner-annotation
policies:
  - policy.yaml
resources:
  - resource.yaml
results:
  - policy: add-owner-annotation
    rule: add-annotation
    kind: Pod
    resources:
      - pod-unowned
    patchedResource: patched/pod-unowned.yaml
    result: pass
```

5. Corré la prueba, luego corrompé la expectativa (cambiá `platform-team` a `platform-teams` dentro del archivo parcheado) y corré de nuevo para ver el diff que imprime la CLI:

```bash
kyverno test .
sed -i 's/platform-team$/platform-teams/' patched/pod-unowned.yaml
kyverno test . --detailed-results
```

**Preguntas**

- **Q25.** ¿Por qué `result: pass` es correcto acá aunque nada fue "validado"? ¿Qué significa `pass` para una regla mutate?
- **Q26.** Escribís a mano `patchedResource` y la prueba falla a pesar de que la annotation está presente y correcta. Listá tres diferencias invisibles que comúnmente causan esto.
- **Q27.** ¿Cuál es el result esperado — y qué va en `patchedResource` — para un Pod que la regla mutate **no** matchea?
- **Q28.** ¿Qué campo reemplaza a `patchedResource` cuando la política es un `mutate` sobre recursos **existentes** (`mutate.targets`), y qué debe declarar también la prueba?

---

## Ejercicio 7 — Reglas generate y fuentes de clonado

1. `~/kca-3.2-lab/gen-netpol/policy.yaml`:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-networkpolicy
spec:
  rules:
    - name: default-deny
      match:
        any:
          - resources:
              kinds:
                - Namespace
      generate:
        apiVersion: networking.k8s.io/v1
        kind: NetworkPolicy
        name: default-deny
        namespace: "{{ request.object.metadata.name }}"
        synchronize: true
        data:
          spec:
            podSelector: {}
            policyTypes:
              - Ingress
              - Egress
```

2. Fixture disparador `resource.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: team-alpha
```

3. Objeto downstream esperado `expected-netpol.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: team-alpha
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
```

4. Manifiesto de prueba:

```yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: add-networkpolicy
policies:
  - policy.yaml
resources:
  - resource.yaml
results:
  - policy: add-networkpolicy
    rule: default-deny
    kind: Namespace
    resources:
      - team-alpha
    generatedResource: expected-netpol.yaml
    result: pass
```

5. Corré la prueba:

```bash
kyverno test . --detailed-results
```

**Preguntas**

- **Q29.** El disparador es un `Namespace` pero el objeto aseverado es una `NetworkPolicy`. ¿Cuál va en `results[].kind` y `results[].resources`, y cuál va en `generatedResource`?
- **Q30.** Reescribí la regla para usar `generate.clone` desde un Secret fuente en el namespace `platform`. ¿Qué campo extra debe declarar la prueba, y qué debe aparecer en `resources:`?
- **Q31.** `synchronize: true` está seteado. ¿Ese comportamiento es ejercitado por `kyverno test`? ¿Qué clase de bug de generate no puede, por lo tanto, atrapar nunca este subcomando?

---

## Ejercicio 8 — PolicyException produce `skip`

1. Volvé al directorio `require-labels` y agregá `exception.yaml`:

```yaml
apiVersion: kyverno.io/v2        # kyverno.io/v2beta1 on Kyverno < 1.13
kind: PolicyException
metadata:
  name: allow-legacy-pod
  namespace: kyverno
spec:
  exceptions:
    - policyName: require-labels
      ruleNames:
        - check-for-labels
  match:
    any:
      - resources:
          kinds:
            - Pod
          namespaces:
            - default
          names:
            - pod-without-label
```

2. Registralo en el manifiesto de prueba y cambiá la expectativa afectada:

```yaml
exceptions:
  - exception.yaml
```

```yaml
  - policy: require-labels
    rule: check-for-labels
    kind: Pod
    resources:
      - pod-without-label
    result: skip     # was: fail
```

3. Corré:

```bash
kyverno test . --detailed-results
```

4. Borrá la restricción `names:` de la excepción, volvé a correr, y observá el radio de impacto.

**Preguntas**

- **Q32.** ¿Por qué el recurso excluido se reporta como `skip` en vez de `pass`? ¿Qué se perdería operativamente si reportara `pass`?
- **Q33.** Se mergea una excepción al repo. ¿Qué *dos* pruebas debería exigir el revisor en el mismo pull request?
- **Q34.** Después del paso 4, la excepción matchea todos los Pods en `default`. ¿Qué aserción en tu suite falla, y por qué esa falla es la propiedad de seguridad más importante del mecanismo de excepciones?

---

## Ejercicio 9 — Seleccionar casos, repositorios remotos y cableado de CI

1. Mové la prueba a la ubicación convencional y arreglá las rutas relativas:

```bash
cd ~/kca-3.2-lab/require-labels
mkdir -p .kyverno-test
git mv kyverno-test.yaml .kyverno-test/ 2>/dev/null || mv kyverno-test.yaml .kyverno-test/
sed -i 's|- policy.yaml|- ../policy.yaml|; s|- resources.yaml|- ../resources.yaml|; s|- exception.yaml|- ../exception.yaml|; s|variables: values.yaml|variables: ../values.yaml|; s|userinfo: userinfo.yaml|userinfo: ../userinfo.yaml|' .kyverno-test/kyverno-test.yaml
```

2. Corré todo el laboratorio recursivamente desde la raíz:

```bash
cd ~/kca-3.2-lab && kyverno test .
```

3. Corré un solo caso:

```bash
kyverno test . -t "policy=require-labels,rule=check-for-labels,resource=pod-without-label"
kyverno test . -t "policy=add-owner-annotation"
```

4. Corré un archivo con nombre diferente:

```bash
cp .kyverno-test/kyverno-test.yaml /tmp/smoke.yaml 2>/dev/null || true
kyverno test require-labels/.kyverno-test -f kyverno-test.yaml
```

5. Corré el corpus upstream directamente desde GitHub:

```bash
kyverno test https://github.com/kyverno/policies/pod-security --git-branch main
```

6. Cableá el gate:

```makefile
.PHONY: policy-test
policy-test:
	kyverno test ./policies --remove-color --detailed-results
```

```yaml
# .github/workflows/policy.yaml
name: policy
on: [pull_request]
jobs:
  kyverno-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: kyverno/action-install-cli@v0.2.0
      - run: kyverno test ./policies --remove-color --detailed-results
```

**Preguntas**

- **Q35.** ¿Por qué importó el `sed` del paso 1 sobre las rutas? Enunciá la regla de resolución de rutas en una oración.
- **Q36.** `kyverno test .` recorrió el árbol y encontró tres suites. ¿Cuál es el nombre de archivo exacto que buscó, y qué le pasa a una suite llamada `tests.yaml`?
- **Q37.** El selector `-t "policy=add-owner-annotation"` corrió un subconjunto. ¿Cuál es el peligro de dejar un selector en una invocación de CI?
- **Q38.** El job de CI fija la CLI vía una action pero el cluster corre Kyverno 1.11. ¿Qué clase silenciosa de falso-verde crea ese desajuste?
- **Q39.** ¿En qué parte del proceso de release de CNCF/Kyverno el target de repositorio git se vuelve útil? Da un flujo de trabajo concreto.

---

## Ejercicio 10 — Ejercicio de troubleshooting

Rompé cada ítem, corré `kyverno test . --detailed-results`, registrá el síntoma, luego reparalo.

1. Cambiá `apiVersion` en `kyverno-test.yaml` a `cli.kyverno.io/v1`.
2. Cambiá `kind: Pod` a `kind: pod` en una entrada de result.
3. Renombrá un fixture en `resources.yaml` pero no en la lista `resources:` de la prueba.
4. Apuntá `policies:` a un archivo que no existe.
5. Poné dos políticas en `policy.yaml` con el mismo `metadata.name`.
6. Quitá `result:` de una entrada por completo.
7. Agregá una entrada de result para un nombre de regla que la política no define.

**Preguntas**

- **Q40.** ¿Cuáles de los siete rompen el *loader* (nada se evalúa en absoluto) y cuáles producen un `Fail` por fila? ¿Por qué importa la distinción al triar un pipeline en rojo?
- **Q41.** Los casos 2, 3 y 7 afloran como la misma cadena de razón. ¿Cuál es, y cuál es el comando más rápido para averiguar cuál de los tres estás mirando?
- **Q42.** ¿Cuál es el código de salida en los casos de falla del loader, y qué implica eso sobre un gate de CI que solo chequea el código de salida?

---

## Referencia de campos y flags

| Campo del manifiesto Test | Propósito |
|---|---|
| `policies` | Manifiestos de política a cargar (rutas relativas al archivo de prueba) |
| `resources` | Recursos candidatos a los que se aplican las políticas |
| `variables` | Archivo `kind: Value` — `globalValues`, values por recurso, `namespaceSelector`, `subresources` |
| `userinfo` | Archivo `kind: UserInfo` — `userInfo`, `roles`, `clusterRoles` |
| `exceptions` | Manifiestos `PolicyException` a cargar |
| `results[].policy` / `.rule` / `.kind` / `.resources` | Selecciona la entrada del report que se está aseverando |
| `results[].result` | Resultado esperado: `pass`, `fail`, `skip`, `error`, `warn` |
| `results[].patchedResource` | Objeto post-mutación esperado |
| `results[].generatedResource` | Objeto downstream esperado de una regla generate |
| `results[].cloneSourceResource` | Objeto fuente para `generate.clone` |
| `results[].isValidatingAdmissionPolicy` | Aseverar contra una ValidatingAdmissionPolicy generada por Kyverno |

| Flag | Uso |
|---|---|
| `-f, --file-name` | Nombre de archivo de prueba no-default |
| `-t, --test-case-selector` | Correr un subconjunto por policy/rule/resource |
| `--fail-only` | Imprimir solo las filas que fallan |
| `--detailed-results` | Agregar la columna `REASON` |
| `--remove-color` | Salida sin ANSI para logs |
| `-b, --git-branch` | Branch cuando el target es una URL de git |
| `--registry` | Permitir acceso al registry usando credenciales locales de Docker |

---

## Clave de respuestas

<details>
<summary><strong>Mostrar respuestas (Q1–Q42)</strong></summary>

**Q1.** El motor de Kyverno está vendoreado *dentro del binario de la CLI*: las políticas se evalúan en el propio proceso contra YAML en disco, sin API server, sin admission webhook y sin controlador de Kyverno involucrados. Consecuencias para CI: no hay cluster que aprovisionar, no hay credenciales que inyectar, no hay inestabilidad por el estado del cluster, y el job puede correr en un pull request antes de que se despliegue nada. También significa que la prueba solo demuestra lo que el motor computa localmente — no que el webhook esté registrado, alcanzable, o configurado con el mismo `failurePolicy`.

**Q2.** `--registry`. Hace que la CLI contacte a los registries de imágenes usando credenciales locales de Docker para poblar datos de imagen (usado por reglas `verifyImages` y entradas de contexto `imageData`). Eso convierte una prueba hermética y determinista en una que depende de la alcanzabilidad de la red, la disponibilidad del registry, los rate limits y el vencimiento de credenciales. Mantenelo apagado por defecto; aislá las suites que dependen del registry en un job separado y claramente etiquetado.

**Q3.** `kyverno-test.yaml` (también se acepta una variante `kyverno-test.yml`). Los targets de directorio se recorren **recursivamente**, y cada archivo con ese nombre se carga como una suite. Cualquier otro nombre de archivo requiere `-f/--file-name`.

**Q4.** `RESULT` es el resultado de la **aserción**, no el resultado de la política: `Pass` significa *que el resultado real del motor igualó al resultado esperado que declaraste*. La fila 2 declaró `result: fail` (el Pod es genuinamente no conforme) y el motor efectivamente produjo `fail`, así que la aserción pasó. La lectura errónea es común porque las mismas dos palabras — pass/fail — nombran dos capas diferentes; una suite llena de filas `Pass` puede estar aseverando que toda política falla.

**Q5.** Las rutas se resuelven **relativas al propio directorio del manifiesto de prueba**, nunca relativas al CWD de tu shell. Correr `kyverno test ~/kca-3.2-lab/require-labels` desde `/tmp` produce una salida idéntica, que es exactamente por qué las suites pueden vivir en un subdirectorio `.kyverno-test/` y referenciar `../policy.yaml`.

**Q6.** Permite que una entrada asevere la misma tupla `policy`/`rule`/`kind`/`result` a lo largo de muchos recursos — la forma natural para "estos ocho Pods violan todos la regla". El campo singular deprecado es `resource:`; todavía parsea en releases actuales pero no debería usarse en material nuevo.

**Q7.** Igual correría, pero la aserción se vuelve ambigua: con varias reglas en una política la CLI no puede saber a qué entrada de report de qué regla te referías, así que podés obtener un falso verde cuando la regla *equivocada* produjo el resultado esperado, o desajustes espurios. Siempre fijá `rule:`.

**Q8.** `$?` después de un pipeline devuelve el estado de salida del **último** comando del pipeline — `tee`, que prácticamente siempre sale con 0. Pasar una corrida de prueba por `tee` por lo tanto convierte una suite que falla en un job verde. `${PIPESTATUS[0]}` recupera el estado real de `kyverno test`. (Equivalentemente: `set -o pipefail`.)

**Q9.** `--fail-only` colapsa el equivalente a 200 políticas de filas verdes hasta dejar solo la regresión, y `--detailed-results` agrega la columna `REASON` que dice *qué* divergió (`Want pass, got fail`, `Not found`, el mensaje de validación). Juntos convierten un log de mil líneas en un puñado de líneas accionables. `--remove-color` es una tercera adición, cosmética pero importante, para colectores de logs.

**Q10.** (1) Está acoplado a una cadena de resumen legible por humanos cuyo texto cambió entre releases de la CLI — un renombre silenciosamente vuelve el gate siempre-verde. (2) No puede distinguir "0 tests failed" de "la suite nunca cargó y corrieron 0 pruebas", ni de un error del loader que no imprimió nada. El código de salida cubre ambos casos; el grep no cubre ninguno.

**Q11.** `skip` — la regla fue seleccionada por `match`/`exclude` pero sus `preconditions` evaluaron a falso, así que el motor nunca evaluó la conformidad. `fail` — la regla fue evaluada por completo y el recurso la violó.

**Q12.** La sustitución de variables falló: `{{ request.object.metadata.annotations."corp.io/owner" }}` no resuelve a nada para un Pod sin esa annotation, y Kyverno trata una variable irresoluble como un error de ejecución de la regla en vez de una cadena vacía. El arreglo es un default de JMESPath: `{{ request.object.metadata.annotations."corp.io/owner" || '' }}` — tras lo cual la regla evalúa determinísticamente para todo Pod.

**Q13.** Un `error` no es una decisión. Con el `failurePolicy: Fail` del webhook (el default de Kyverno para reglas que se aplican con enforcement), un error del motor en tiempo de admisión rechaza el request — así que una regla que da error sobre una forma común de recurso se convierte en una caída a nivel de todo el cluster para ese tipo de recurso. Con `failurePolicy: Ignore` pasa lo opuesto: el request se admite sin control, y el control deja de aplicarse silenciosamente. De cualquier manera, un `error` en una prueba de la CLI es un defecto a arreglar, nunca una expectativa a consagrar.

**Q14.** `fail`. Una vez que `tier: backend` está presente la precondition se satisface, la regla se evalúa, y el Pod no tiene la annotation `corp.io/owner`, así que el pattern no matchea. Este es precisamente el par de casos que lleva una buena suite: un recurso que saltea la regla y uno que la alcanza.

**Q15.** No. `validationFailureAction` controla el *enforcement* en la admisión (rechazar vs. solo reportar); el resultado de evaluación de la regla — y por lo tanto el resultado de policy-report que la CLI asevera — es `fail` en cualquier caso. Este es un distractor frecuente del examen. (En el tipo más nuevo `ValidatingPolicy` basado en CEL, `validationActions` puede incluir `Warn`, que es de donde viene el valor de result `warn`; las violaciones en modo audit de un `ClusterPolicy` clásico se siguen reportando como `fail`.)

**Q16.** `autogen-check-for-labels` para controladores de Pod (Deployment, StatefulSet, DaemonSet, Job, ReplicaSet, ReplicationController), y `autogen-cronjob-check-for-labels` para CronJob — el nivel extra de anidamiento `jobTemplate` obtiene su propia regla generada.

**Q17.** `Not found` significa que la CLI **no encontró ninguna entrada de report** que matcheara la tupla `policy`+`rule`+`kind`+`resource` que aseveraste, así que no había nada contra qué comparar un result. Causas comunes: (1) el nombre de regla es el que no lleva prefijo para un recurso de controlador autogenerado; (2) el nombre de recurso o namespace en `results[].resources` no coincide con `metadata.name`/`metadata.namespace` en el fixture; (3) el `kind` está mal o con mayúsculas/minúsculas incorrectas, así que la regla nunca matcheó el recurso en absoluto.

**Q18.** `pod-policies.kyverno.io/autogen-controllers`. Setearla a `none` deshabilita la generación por completo — tras lo cual `autogen-check-for-labels` ya no existe, la expectativa del Deployment vuelve a `Not found`, y el Deployment ya no se controla en absoluto. La annotation también puede acotarse a una lista, p. ej. `Deployment,StatefulSet`.

**Q19.** Porque en un cluster real casi nada crea Pods desnudos — lo hacen los Deployments, StatefulSets, Jobs y CronJobs. Si autogen está mal configurado o deshabilitado, la política se ve verde contra los fixtures de Pod mientras cada workload realmente desplegado pasa sin control. El fixture de controlador es el que prueba lo que producción va a enviar.

**Q20.** `CREATE`. Las reglas condicionadas a que `request.operation` sea `UPDATE` o `DELETE` por lo tanto se saltean por defecto, y una suite que nunca setea `globalValues` reportará `skip` para ellas — una suite verde que no probó nada. Aseverá ambas operaciones explícitamente.

**Q21.** `globalValues` se aplica a cada política y cada recurso de la suite (el contexto ambiental del request: operación, values a nivel de todo el cluster). `spec.policies[].resources[].values` acota un value a un recurso bajo una política. La forma por recurso es obligatoria siempre que dos fixtures deban ver values *diferentes* para la misma variable — el caso estándar siendo un recurso que satisface una condición dirigida por contexto y uno que no, dentro de una sola corrida.

**Q22.** `error`. `request.userInfo.groups` es irresoluble sin un archivo `userinfo:`, y una variable no resuelta es un error de ejecución de la regla, no una lista vacía. Por eso las reglas condicionadas por identidad requieren el fixture `UserInfo` incluso para producir una prueba negativa significativa.

**Q23.** Las reglas que matchean sobre labels de namespace (o referencian metadata de `request.namespace`) necesitan las labels del namespace, que no están presentes en los manifiestos de recursos. En runtime Kyverno las obtiene del API server o de su caché de namespaces; offline, `namespaceSelector` en el archivo de values sustituye a esa consulta.

**Q24.** No fielmente — no hay API server al que llamar. Proveé el value que el APICall habría devuelto a través del archivo de variables (`values` por regla/por recurso indexados por el nombre de la entrada de contexto), lo cual fija la prueba a una respuesta conocida. Eso hace la prueba determinista pero también significa que valida tu *lógica*, no la forma en vivo de la API; la forma debe verificarse por separado contra un cluster real.

**Q25.** Para una regla mutate, `pass` significa que la regla matcheó y aplicó su patch exitosamente, y el objeto resultante iguala a `patchedResource`. La aserción vive en la comparación del recurso parcheado; `result: pass` asevera que la regla se disparó en absoluto.

**Q26.** (1) Las diferencias de orden de claves e indentación son irrelevantes, pero los campos *agregados* no lo son — la salida de Kyverno lleva campos con defaults/normalizados que tu copia escrita a mano no tiene. (2) Annotations de procedencia que el motor adjunta a los objetos mutados. (3) Coerción de tipos: `"false"` vs `false`, `8080` vs `"8080"`, y diferencias de newline final/comillas en cadenas multilínea. Generar el archivo con `kyverno apply -o` elimina las tres; regeneralo cada vez que la política o la versión de la CLI cambie, y revisá el diff en la revisión de código.

**Q27.** El result esperado es `skip` (la regla no era aplicable), y `patchedResource` se omite por completo — no hay objeto parcheado que comparar. Declarar un `patchedResource` sin cambios para un recurso que no matchea es una forma común de escribir una prueba que pasa por la razón equivocada.

**Q28.** Para políticas de mutate sobre existentes, los objetos target van en `results[].patchedResources` (los *targets* mutados, no el disparador), y la prueba también debe declarar los propios objetos target para que el motor tenga algo que mutar — típicamente vía una lista `targetResources:` junto a `resources:`. El recurso disparador sigue identificando la fila.

**Q29.** `kind: Namespace` y `resources: [team-alpha]` identifican el **disparador** — la entrada de report está adjunta al objeto que causó que la regla se disparara. `generatedResource` apunta a un archivo que contiene el objeto **downstream** esperado (la NetworkPolicy).

**Q30.** Reemplazá `generate.data` por `generate.clone: {namespace: platform, name: <secret-name>}`. La prueba debe entonces declarar `cloneSourceResource: <ruta al manifiesto del Secret fuente>` en la entrada de result, y el Secret fuente debe ser cargable — la CLI no puede leerlo de un cluster. El Namespace disparador sigue siendo la entrada en `resources:`.

**Q31.** No. `synchronize: true` es un comportamiento del *controlador* — el controlador de generate observa la fuente y el objeto generado y reconcilia la deriva con el tiempo. `kyverno test` evalúa una única decisión en tiempo de admisión, así que nunca puede atrapar bugs de sincronización, bugs de propagación de borrado, o el comportamiento de `orphanDownstreamOnPolicyDelete`. Esos requieren una prueba de integración contra un cluster real.

**Q32.** Porque la regla *no fue evaluada* para ese recurso — la excepción lo sacó del alcance. Reportar `pass` sería una mentira en el policy report: los dashboards y la evidencia de cumplimiento contarían un workload exento como conforme. `skip` mantiene las exenciones visibles y contables, que es lo que le permite a un equipo de plataforma auditar cuánto del parque está corriendo bajo excepciones.

**Q33.** (1) Una prueba que asevera que el recurso exento ahora da `skip` — prueba de que la excepción funciona. (2) Una prueba que asevera que un recurso *vecino*, que la excepción no debe cubrir, sigue dando `fail` — prueba de que la excepción está acotada. Sin la segunda prueba, un `match` demasiado amplio deshabilita la política en toda la flota y toda aserción restante sigue viéndose razonable.

**Q34.** La aserción para `pod-with-label` (o cualquier otro Pod en `default` que se espera sea evaluado) se rompe, porque ahora reporta `skip` en vez de `pass`. Esa es la propiedad de seguridad: una excepción cuyo alcance se ensancha silenciosamente no puede pasar una suite que fija el caso negativo, así que el radio de impacto se atrapa en la revisión de código en vez de en producción.

**Q35.** Porque la resolución de rutas está anclada al directorio del manifiesto de prueba: mover el manifiesto a `.kyverno-test/` bajó el ancla un nivel, así que `policy.yaml` tuvo que convertirse en `../policy.yaml`. Regla: *toda ruta dentro de un manifiesto `Test` es relativa al propio directorio de ese manifiesto.*

**Q36.** `kyverno-test.yaml`. Una suite llamada `tests.yaml` es invisible para una corrida recursiva — no se ejecuta silenciosamente, y el resumen reporta contento sobre lo que sea que haya encontrado. O la renombrás o pasás `-f tests.yaml`, y tené en cuenta que `-f` se aplica a toda la invocación.

**Q37.** Un selector acota la corrida a un subconjunto mientras igual sale con 0 en caso de éxito, así que el pipeline reporta verde habiendo ejecutado una fracción de la suite. Los selectores son una herramienta local de debugging; una invocación de CI commiteada debe correr el corpus completo.

**Q38.** El motor embebido de la CLI es 1.13 mientras el cluster aplica 1.11. El comportamiento que cambió entre esas versiones — nuevos operadores, cobertura de autogen, ubicación de `failureAction`, manejo del apiVersion de excepciones, defaulting — es evaluado por el motor *más nuevo*, así que las pruebas pueden estar verdes contra semánticas que el cluster no implementa. Fijá la versión de la CLI a la versión de Kyverno desplegada y subí ambas juntas.

**Q39.** Pruebas de regresión de una actualización de Kyverno: apuntá la CLI *nueva* al corpus de políticas upstream (`kyverno test https://github.com/kyverno/policies/... -b main`) o al tag de tu propio repositorio de políticas antes de rotar el controlador. La misma técnica valida una biblioteca de políticas curada consumida desde un repo remoto sin vendorearla primero.

**Q40.** Fallas del loader: 1 (`apiVersion` desconocido para el kind `Test`), 4 (archivo de política faltante), 5 (nombres de política duplicados) — nada se evalúa y no se imprime tabla de resultados. `Fail` por fila: 2, 3, 7 (`Not found`) y 6 (entrada de result inválida/incompleta, que también puede rechazarse en tiempo de parseo según la versión). La distinción es la primera pregunta de triaje: una falla del loader significa que *la suite no corrió*, así que "0 failures" no lleva información — tratala como más severa que un desajuste genuino de aserción.

**Q41.** `Not found` — ninguna entrada de report matcheó la tupla aseverada. Discriminador más rápido: corré `kyverno apply policy.yaml --resource resources.yaml --policy-report` y leé el report real — lista los nombres de política reales, nombres de regla (incluyendo prefijos `autogen-`), kinds y nombres de recurso, así podés diffear tus entradas `results[]` contra la verdad de base en vez de adivinar.

**Q42.** No-cero (1), lo mismo que una falla de aserción — la CLI no las distingue por código. Así que un gate por código de salida sí falla el build correctamente, pero no puede decirte *si algo corrió*. Emparejá el gate con `--detailed-results` en el log, y para pipelines de alto riesgo aseverá un conteo mínimo de pruebas esperadas para que una corrida accidentalmente vacía no pueda pasar.

</details>

---

### Fuentes

- Kyverno CLI — referencia del comando `test`: https://kyverno.io/docs/kyverno-cli/usage/test/
- Kyverno CLI — comando `apply` (usado para generar `patchedResource`): https://kyverno.io/docs/kyverno-cli/usage/apply/
- Kyverno CLI — instalación y visión general: https://kyverno.io/docs/kyverno-cli/
- Raíz de la documentación de Kyverno (tipos de política, autogen, excepciones, variables): https://kyverno.io/docs/
- Fuente de verdad de la CLI de Kyverno para flags y schemas de manifiestos: https://github.com/kyverno/kyverno/tree/main/cmd/cli/kubectl-kyverno
- Corpus de pruebas del mundo real (`.kyverno-test/kyverno-test.yaml` por política): https://github.com/kyverno/policies
- Currículum de KCA: https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf