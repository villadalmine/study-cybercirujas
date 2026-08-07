# 3.1 — Ejercicios guiados: Continuous Integration Fundamentals and Best Practices

> Estos ejercicios asumen una workstation Linux con `git`, `go` (≥1.22), `buildah` o `docker`, `kubectl`, `tkn`, `syft`, `grype`/`trivy` y `cosign` (v2) instalados, y acceso a un cluster de Kubernetes (kind/minikube sirven) y a un registry OCI (`ttl.sh` es un registry efímero público muy cómodo para practicar sin credenciales).
>
> La CI en un contexto cloud-native no es "correr los tests": es la **cadena de custodia** que transforma un commit en un artefacto firmado, trazable y desplegable. Cada ejercicio agrega un eslabón de esa cadena.

---

## Ejercicio 1 — Un pipeline de CI mínimo con feedback rápido

**Objetivo:** montar trunk-based development con un pipeline `pull_request`-triggered que corre lint + build + test, y entender por qué el orden y el *fail-fast* importan.

### Pasos

1. Creá el proyecto y un módulo Go trivial pero testeable:

   ```bash
   mkdir hello-ci && cd hello-ci
   git init -b main
   go mod init example.com/hello
   ```

2. Escribí `greeting.go`:

   ```go
   package hello

   import "fmt"

   func Greet(name string) string {
       if name == "" {
           name = "world"
       }
       return fmt.Sprintf("hello, %s", name)
   }
   ```

3. Escribí `greeting_test.go`:

   ```go
   package hello

   import "testing"

   func TestGreet(t *testing.T) {
       cases := map[string]string{"": "hello, world", "ada": "hello, ada"}
       for in, want := range cases {
           if got := Greet(in); got != want {
               t.Errorf("Greet(%q) = %q, want %q", in, got, want)
           }
       }
   }
   ```

4. Verificá localmente **antes** de escribir cualquier pipeline (la CI no reemplaza el bucle local, lo protege):

   ```bash
   go vet ./...
   go test ./...
   ```

   Salida esperada:

   ```
   ok      example.com/hello    0.004s
   ```

5. Creá el workflow en `.github/workflows/ci.yaml`. Notá el orden de los steps (los baratos y más propensos a fallar primero) y el uso de cache de dependencias:

   ```yaml
   name: ci
   on:
     pull_request:
       branches: [main]
     push:
       branches: [main]

   permissions:
     contents: read

   concurrency:
     group: ci-${{ github.ref }}
     cancel-in-progress: true

   jobs:
     verify:
       runs-on: ubuntu-latest
       steps:
         - uses: actions/checkout@v4
         - uses: actions/setup-go@v5
           with:
             go-version: '1.22'
             cache: true          # cachea el module + build cache
         - name: vet (análisis estático, barato)
           run: go vet ./...
         - name: build
           run: go build ./...
         - name: test
           run: go test -race -count=1 ./...
   ```

6. Configurá branch protection en `main` para que este check sea **obligatorio** antes de mergear (Settings → Branches → *Require status checks to pass*). Sin esto, el pipeline es decorativo: informa pero no *gatekeepea*.

7. Simulá el flujo trunk-based con una rama de vida corta:

   ```bash
   git add . && git commit -m "feat: greeting"
   git switch -c fix/empty-name
   # editá algo, commiteá, abrí un PR
   ```

**Preguntas de verificación (bloque 1)**

1.1 ¿Por qué `go vet` va **antes** de `go test` y no al revés?
1.2 ¿Qué problema concreto resuelve el bloque `concurrency` con `cancel-in-progress: true` en un repo con muchos pushes?
1.3 El check corre en `pull_request` **y** en `push` a `main`. ¿Por qué correrlo en ambos y no solo en el PR?
1.4 ¿Por qué `go test -count=1`? ¿Qué anti-patrón de CI evita ese flag?
1.5 Sin *required status checks* en branch protection, ¿qué garantía pierde la CI aunque el workflow funcione perfecto?

---

## Ejercicio 2 — Build de imagen OCI reproducible y con cache de capas

**Objetivo:** construir una imagen dentro de CI **sin** Docker daemon privilegiado (rootless/daemonless), ordenar el Dockerfile para maximizar el cache hit, y pinnear por digest.

### Pasos

1. Agregá un binario y un `Dockerfile` multi-stage. El orden de instrucciones es la palanca de caching más importante:

   ```dockerfile
   # syntax=docker/dockerfile:1
   FROM golang:1.22 AS build
   WORKDIR /src
   # 1) copiar SOLO los manifests primero: esta capa se invalida
   #    únicamente cuando cambian las dependencias, no el código.
   COPY go.mod go.sum* ./
   RUN go mod download
   # 2) recién ahora el código fuente
   COPY . .
   RUN CGO_ENABLED=0 go build -o /out/app ./cmd/app

   # 3) imagen final mínima, sin toolchain ni shell
   FROM gcr.io/distroless/static:nonroot
   COPY --from=build /out/app /app
   USER nonroot:nonroot
   ENTRYPOINT ["/app"]
   ```

2. Creá `cmd/app/main.go`:

   ```go
   package main

   import (
       "fmt"
       "net/http"

       "example.com/hello"
   )

   func main() {
       http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
           fmt.Fprintln(w, hello.Greet(r.URL.Query().Get("name")))
       })
       http.ListenAndServe(":8080", nil)
   }
   ```

3. Construí con **buildah** (daemonless, rootless), que es lo que usarías en un runner de CI sin socket de Docker:

   ```bash
   buildah bud -t ttl.sh/hello-$(id -u):1h .
   ```

   Salida esperada (abreviada):

   ```
   STEP 1/9: FROM golang:1.22 AS build
   ...
   STEP 9/9: ENTRYPOINT ["/app"]
   COMMIT ttl.sh/hello-1000:1h
   Successfully tagged ttl.sh/hello-1000:1h
   9f2c1e...c4
   ```

4. Empujá al registry efímero y **capturá el digest** (no el tag):

   ```bash
   buildah push ttl.sh/hello-$(id -u):1h \
     --digestfile /tmp/digest.txt
   cat /tmp/digest.txt
   ```

   ```
   sha256:3b1e...9a
   ```

5. Demostrá el valor del cache: cambiá **solo** `greeting.go` (no `go.mod`) y reconstruí. Observá que la capa `go mod download` sale del cache (`--> Using cache`) y solo se recompila desde el `COPY . .`.

6. Referenciá siempre por digest downstream (deployment, escaneo, firma). El tag `:1h` es mutable; el digest `@sha256:...` es inmutable y es lo que hace **reproducible** el pipeline:

   ```bash
   IMAGE="ttl.sh/hello-$(id -u)@$(cat /tmp/digest.txt)"
   echo "$IMAGE"
   ```

**Preguntas de verificación (bloque 2)**

2.1 ¿Por qué `COPY go.mod go.sum* ./` + `go mod download` va **antes** de `COPY . .`? ¿Qué capa se ahorra al cambiar solo código de negocio?
2.2 ¿Qué ventaja de seguridad y de superficie de ataque aporta la imagen final `distroless/static:nonroot` frente a `golang:1.22` o `ubuntu`?
2.3 Un compañero dice "usá siempre el tag `:latest` en el deploy". Dando un ejemplo concreto, ¿por qué eso rompe la reproducibilidad y la trazabilidad de la CI?
2.4 ¿Qué gana el pipeline al usar `buildah` daemonless/rootless en lugar de montar el socket `/var/run/docker.sock` dentro del runner?

---

## Ejercicio 3 — CI como código, nativa de Kubernetes, con Tekton

**Objetivo:** expresar el pipeline *pipeline-as-code* corriendo dentro del cluster: `Task`s reutilizables, un `Pipeline` que las orquesta y un `PipelineRun` que lo dispara sobre un `Workspace` compartido.

### Pasos

1. Instalá Tekton Pipelines en el cluster:

   ```bash
   kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
   kubectl get pods -n tekton-pipelines -w
   ```

   Esperá a que `tekton-pipelines-controller` y `tekton-pipelines-webhook` estén `Running`.

2. Reutilizá una `Task` del catálogo oficial (Tekton Hub) para clonar, en vez de reinventarla:

   ```bash
   kubectl apply -f https://raw.githubusercontent.com/tektoncd/catalog/main/task/git-clone/0.9/git-clone.yaml
   ```

3. Definí una `Task` de test en `task-test.yaml`:

   ```yaml
   apiVersion: tekton.dev/v1
   kind: Task
   metadata:
     name: go-test
   spec:
     workspaces:
       - name: source
     steps:
       - name: test
         image: golang:1.22
         workingDir: $(workspaces.source.path)
         script: |
           #!/usr/bin/env sh
           set -e
           go vet ./...
           go test -race -count=1 ./...
   ```

4. Definí el `Pipeline` que encadena clone → test en `pipeline.yaml`. Notá que el `Workspace` es lo que hace que la segunda `Task` vea lo que clonó la primera:

   ```yaml
   apiVersion: tekton.dev/v1
   kind: Pipeline
   metadata:
     name: ci
   spec:
     params:
       - name: repo-url
         type: string
     workspaces:
       - name: shared
     tasks:
       - name: clone
         taskRef:
           name: git-clone
         params:
           - name: url
             value: $(params.repo-url)
         workspaces:
           - name: output
             workspace: shared
       - name: test
         runAfter: [clone]          # dependencia explícita
         taskRef:
           name: go-test
         workspaces:
           - name: source
             workspace: shared
   ```

5. Disparalo con un `PipelineRun` que aporta el almacenamiento efímero del workspace en `run.yaml`:

   ```yaml
   apiVersion: tekton.dev/v1
   kind: PipelineRun
   metadata:
     generateName: ci-run-
   spec:
     pipelineRef:
       name: ci
     params:
       - name: repo-url
         value: https://github.com/tu-usuario/hello-ci
     workspaces:
       - name: shared
         volumeClaimTemplate:
           spec:
             accessModes: [ReadWriteOnce]
             resources:
               requests:
                 storage: 1Gi
   ```

6. Aplicá y seguí los logs con el CLI `tkn`:

   ```bash
   kubectl apply -f task-test.yaml -f pipeline.yaml
   kubectl create -f run.yaml
   tkn pipelinerun logs --last -f
   ```

   Salida esperada (abreviada):

   ```
   [clone : clone] + git clone https://github.com/tu-usuario/hello-ci ...
   [test : test]  ok   example.com/hello   0.006s
   ```

7. Inspeccioná el estado estructurado del run:

   ```bash
   tkn pipelinerun describe --last
   ```

**Preguntas de verificación (bloque 3)**

3.1 ¿Cuál es la unidad reutilizable en Tekton — `Task`, `Pipeline` o `PipelineRun` — y por qué separar `Pipeline` (definición) de `PipelineRun` (ejecución) es un ejemplo de *pipeline-as-code*?
3.2 Si borrás el `workspace` `shared` del `Pipeline`, ¿qué falla exactamente en la `Task` `test` y por qué?
3.3 `runAfter: [clone]` expresa una dependencia. ¿Qué pasaría con el orden de ejecución si dos `Task`s **no** tuvieran `runAfter` ni compartieran datos?
3.4 Comparado con GitHub Actions (Ejercicio 1), ¿qué gana un equipo de plataforma al correr la CI *dentro* del cluster con Tekton en términos de portabilidad y de reutilización entre repos?

---

## Ejercicio 4 — Shift-left: supply chain security dentro del pipeline

**Objetivo:** convertir el artefacto del Ejercicio 2 en uno *verificable*: generar SBOM, escanear vulnerabilidades, firmar sin gestionar claves (keyless) y adjuntar una atestación de procedencia. Esto es lo que separa "CI que compila" de "CI que produce evidencia".

### Pasos

1. Generá el **SBOM** (Software Bill of Materials) de la imagen con `syft`, en formato estándar SPDX:

   ```bash
   syft "$IMAGE" -o spdx-json=sbom.spdx.json
   ```

   ```
   ✔ Parsed image
   ✔ Cataloged packages   [23 packages]
   ```

2. Escaneá vulnerabilidades **a partir del SBOM** (más rápido y reproducible que re-analizar la imagen):

   ```bash
   grype sbom:sbom.spdx.json --fail-on high
   ```

   Salida esperada:

   ```
   NAME    INSTALLED  FIXED-IN  TYPE  VULNERABILITY  SEVERITY
   ...
   ```

   El flag `--fail-on high` hace que el step **rompa el build** ante cualquier CVE `high` o `critical`: eso es un *quality gate*, no un reporte informativo.

3. Firmá la imagen sin manejar claves privadas, usando el flujo **keyless** de Sigstore (Fulcio emite un cert efímero atado a tu identidad OIDC; Rekor lo registra en un log transparente e inmutable):

   ```bash
   cosign sign --yes "$IMAGE"
   ```

   En CI de GitHub Actions esto requiere `permissions: id-token: write` para que el runner obtenga el token OIDC; localmente abre un flujo de login en el browser.

4. Verificá la firma exigiendo **quién** firmó y **qué issuer** la avala:

   ```bash
   cosign verify "$IMAGE" \
     --certificate-identity-regexp '.*' \
     --certificate-oidc-issuer-regexp '.*' | jq '.[0].optional'
   ```

   > En producción reemplazá los `regexp '.*'` por la identidad y el issuer exactos (p. ej. el repo/workflow de tu CI y `https://token.actions.githubusercontent.com`). Un `verify` que acepta *cualquier* firmante no verifica nada.

5. Adjuntá el SBOM como **atestación firmada** (predicado SPDX) para que viaje junto a la imagen y sea verificable:

   ```bash
   cosign attest --yes --type spdxjson \
     --predicate sbom.spdx.json "$IMAGE"

   cosign verify-attestation "$IMAGE" --type spdxjson \
     --certificate-identity-regexp '.*' \
     --certificate-oidc-issuer-regexp '.*' >/dev/null && echo "OK"
   ```

6. (Conceptual, para conectar con SLSA) La firma prueba *integridad y autoría*; la **provenance** SLSA prueba *cómo se construyó* (qué builder, qué source, qué parámetros). En un pipeline real generarías una atestación de provenance `--type slsaprovenance` desde el builder para alcanzar SLSA Build L2+.

**Preguntas de verificación (bloque 4)**

4.1 Diferenciá con precisión qué garantiza el **SBOM**, qué garantiza la **firma** (cosign) y qué garantiza la **provenance** SLSA. Los tres son evidencia distinta.
4.2 ¿Qué significa "shift-left" y por qué `grype --fail-on high` *dentro* del pipeline es shift-left, mientras que escanear en producción no lo es?
4.3 En el flujo **keyless**, no hay clave privada persistente. ¿Qué rol cumple Fulcio, cuál Rekor, y qué ataque mitiga el hecho de que Rekor sea un *transparency log* append-only?
4.4 ¿Por qué un `cosign verify` con `--certificate-identity-regexp '.*'` es peligroso en un gate de producción? Dá un escenario de compromiso concreto.
4.5 ¿Por qué conviene correr `grype` sobre el `sbom.spdx.json` y no directamente sobre la imagen, cuando el mismo artefacto se escanea muchas veces en el pipeline?

---

## Ejercicio 5 — Best practices y medición del pipeline

**Objetivo:** aplicar las buenas prácticas transversales (trunk-based, paralelismo, gates, hermeticidad) y medir la salud del pipeline con las métricas DORA, que son el "termómetro" objetivo de una práctica de CI.

### Pasos

1. Paralelizá y matriciá la verificación para acortar el *feedback time* — probando varias versiones de runtime a la vez:

   ```yaml
   jobs:
     verify:
       strategy:
         fail-fast: false
         matrix:
           go: ['1.21', '1.22']
       runs-on: ubuntu-latest
       steps:
         - uses: actions/checkout@v4
         - uses: actions/setup-go@v5
           with: { go-version: '${{ matrix.go }}', cache: true }
         - run: go test -race -count=1 ./...
   ```

2. Convertí las etapas en un *fan-out/fan-in* explícito: `lint` y `unit-test` en paralelo, y un job `build-image` que corre **solo si** ambos pasan (`needs:`):

   ```yaml
     build-image:
       needs: [verify]      # gate: no se construye si la verificación falla
       runs-on: ubuntu-latest
       steps:
         - uses: actions/checkout@v4
         - run: echo "buildah bud ..."   # el build del Ejercicio 2
   ```

3. Asegurá **hermeticidad e idempotencia**: pinneá versiones de dependencias (`go.sum`), pinneá acciones por SHA (no por tag mutable), y evitá que un step dependa de estado del runner. Reproducir el mismo commit debe dar el mismo resultado.

4. Configurá los *quality gates* como obligatorios: required status checks + *require branches to be up to date* + revisión por code owners. El pipeline debe ser la única puerta hacia `main`.

5. Instrumentá las **cuatro métricas DORA** y discutí de dónde sale cada dato en tu pipeline:

   | Métrica | Qué mide | Fuente en el pipeline |
   |---|---|---|
   | Deployment Frequency | Con qué frecuencia llegás a producción | conteo de deploys exitosos / tiempo |
   | Lead Time for Changes | Commit → producción | timestamp del commit vs. timestamp del deploy |
   | Change Failure Rate | % de deploys que causan incidente/rollback | incidentes / deploys |
   | Failed Deployment Recovery Time (MTTR) | Cuánto tardás en recuperarte | inicio del incidente → restauración |

6. Calculá el lead time de un cambio real:

   ```bash
   git log -1 --format=%cI HEAD          # timestamp del commit
   # comparalo contra el timestamp del deploy exitoso correspondiente
   ```

**Preguntas de verificación (bloque 5)**

5.1 Explicá `fail-fast: false` en la matriz: ¿en qué se diferencia el comportamiento con `true` y cuándo querés cada uno?
5.2 ¿Qué garantiza `needs: [verify]` en el job `build-image` y por qué es un ejemplo de *fail-fast* a nivel pipeline?
5.3 Pinnear una GitHub Action por tag (`@v4`) vs. por SHA completo: ¿qué riesgo de supply chain elimina el pin por SHA? Conectalo con el Ejercicio 4.
5.4 De las cuatro métricas DORA, dos son de *velocidad* (throughput) y dos de *estabilidad*. Nombralas y explicá por qué medir solo velocidad incentiva un comportamiento peligroso.
5.5 Definí "hermetic build". ¿Qué anti-patrón concreto de este pipeline lo rompería, y por qué eso destruye la reproducibilidad que buscamos desde el Ejercicio 2?

---

## Respuestas

<details>
<summary>Ver soluciones y explicaciones</summary>

### Bloque 1 — Pipeline mínimo

**1.1** `go vet` es análisis estático: corre en milisegundos y no necesita ejecutar el binario. Va primero por el principio de *fail-fast en el step más barato*: si hay un error detectable estáticamente (formato de `Printf` mal, código muerto), querés enterarte en 2 segundos y no después de compilar y correr toda la suite de tests. La regla general de CI es ordenar los steps de *más barato y más propenso a fallar* → *más caro*.

**1.2** Sin `concurrency`, cada push a una rama con PR abierto lanza un run nuevo mientras los anteriores siguen corriendo, desperdiciando runners y ensuciando el estado del check. `group: ci-${{ github.ref }}` agrupa por rama y `cancel-in-progress: true` cancela el run anterior de esa misma rama cuando llega uno nuevo: solo el commit más reciente se verifica. Ahorra cómputo y da feedback más rápido sobre el estado actual.

**1.3** El PR verifica el *merge propuesto*; el push a `main` verifica el *estado real de la rama protegida* después del merge. Son estados distintos: dos PRs pueden pasar por separado y romper `main` al mergearse juntos (*semantic merge conflict*). Correr en `push` a `main` detecta esa regresión post-merge. (La forma más fuerte de evitarlo es *require branches to be up to date*, ver 5.2/quality gates.)

**1.4** Go cachea resultados de tests: un `go test` que ya pasó puede reportar `ok (cached)` sin volver a ejecutar. `-count=1` fuerza la re-ejecución. Evita el anti-patrón de una CI que reporta "verde" a partir de un resultado cacheado que ya no corresponde al código actual — la CI debe ejecutar, no recordar.

**1.5** Perdés el *enforcement*. El workflow puede correr y fallar, pero sin *required status checks* nada impide mergear un PR con la CI en rojo. La CI pasa de ser un **gate** (bloquea) a ser un **reporte** (informa y se ignora). El valor de un pipeline de CI está tanto en la señal como en que esa señal sea vinculante.

### Bloque 2 — Build de imagen

**2.1** El caching de capas de OCI es por instrucción y en cadena: al cambiar cualquier archivo copiado en una capa, esa capa y **todas las siguientes** se invalidan. `go mod download` es la operación lenta (baja la red de dependencias). Copiando solo `go.mod`/`go.sum` primero, esa capa solo se invalida cuando cambian las *dependencias*, no cuando cambia el código de negocio. Al editar `greeting.go`, la capa de descarga de módulos sale del cache y solo se recompila desde `COPY . .`.

**2.2** `distroless/static:nonroot` no tiene shell, package manager, ni utilidades de sistema, y corre como usuario no-root. Reduce drásticamente la superficie de ataque (no hay `sh` para un atacante que logre RCE, menos paquetes = menos CVEs) y el tamaño. `golang:1.22` incluye todo el toolchain de compilación, que no se necesita en runtime y solo agrega vulnerabilidades y peso.

**2.3** `:latest` es un tag mutable: dos `docker pull hello:latest` en momentos distintos pueden traer imágenes con digests diferentes. Si el deploy referencia `:latest`, no sabés *qué* código está corriendo, no podés reproducir un incidente, y el escaneo/firma del Ejercicio 4 pueden haberse hecho sobre un digest distinto al desplegado. Referenciar por `@sha256:...` (inmutable) garantiza que build, scan, firma y deploy hablan del *mismo* artefacto.

**2.4** Montar `/var/run/docker.sock` en el runner es equivalente a darle root en el host (quien controla el daemon controla la máquina) y crea acoplamiento con un daemon privilegiado compartido. `buildah` daemonless/rootless construye sin daemon y sin privilegios de root, lo que aísla mejor los builds concurrentes y elimina esa escalada de privilegios — importante en runners multi-tenant de una plataforma.

### Bloque 3 — Tekton

**3.1** La unidad reutilizable es la **`Task`** (y el `Pipeline` que las compone); ambas son *definiciones* declarativas versionables en Git. El `PipelineRun` es una *instancia de ejecución* con sus parámetros y workspaces concretos. Separar definición (`Pipeline`) de ejecución (`PipelineRun`) es exactamente *pipeline-as-code*: la lógica del pipeline es un objeto declarativo, revisable y reutilizable, independiente de cada corrida particular — como separar una clase de sus instancias.

**3.2** La `Task` `test` corre en un pod distinto al de `clone`. El código clonado vive en el `Workspace` compartido (un volumen). Sin ese workspace, `test` arranca con un working dir vacío y `go test ./...` falla porque no hay fuentes: el workspace es el único mecanismo que hace persistir datos *entre* Tasks, que por diseño no comparten filesystem.

**3.3** Sin `runAfter` ni dependencia de datos, Tekton considera las `Task`s independientes y las ejecuta **en paralelo**. `runAfter: [clone]` impone el orden secuencial necesario (no podés testear lo que no clonaste). El paralelismo por defecto es una ventaja: Tekton corre en paralelo todo lo que no declaraste dependiente.

**3.4** Corriendo dentro del cluster, el mismo pipeline es **portable** entre cualquier cluster de Kubernetes (no atado a un SaaS de CI concreto) y las `Task`s son **reutilizables** entre repos vía el catálogo/Tekton Hub. Un equipo de plataforma publica `Task`s golden (build firmado, escaneo, deploy) una vez y todos los repos las consumen, con las mismas primitivas de RBAC, scheduling y observabilidad que el resto de sus cargas.

### Bloque 4 — Supply chain

**4.1** — **SBOM**: *qué contiene* el artefacto (inventario de paquetes y versiones). Responde "¿estoy afectado por CVE-X?". — **Firma (cosign)**: *integridad y autoría* — que la imagen no fue alterada y que la firmó una identidad conocida. Responde "¿es esta exactamente la imagen que produjo mi CI?". — **Provenance SLSA**: *cómo se construyó* — qué builder, qué source commit, qué parámetros. Responde "¿fue construida por mi pipeline confiable a partir de mi código?". Son tres evidencias ortogonales: podés tener SBOM sin firma, o firma sin provenance.

**4.2** "Shift-left" = mover controles de calidad/seguridad lo más temprano posible en el ciclo (izquierda de la línea de tiempo dev→prod). `grype --fail-on high` *dentro* del pipeline bloquea el artefacto vulnerable **antes** de que exista un deploy: el costo de arreglarlo es mínimo. Escanear en producción es "shift-right": detectás la vulnerabilidad cuando ya está expuesta y ya explotable, y el arreglo implica un incident + hotfix + rollback. Mismo hallazgo, órdenes de magnitud de diferencia en costo y riesgo.

**4.3** **Fulcio** es la CA que, contra un token OIDC válido, emite un certificado X.509 de *corta vida* atado a tu identidad — así no hay clave privada persistente que robar. **Rekor** es un *transparency log* append-only donde se registra la firma y el certificado. Al ser append-only e inmutable (Merkle), un atacante no puede firmar algo retroactivamente sin dejar rastro: cualquiera puede auditar que una firma existió en un momento dado. Mitiga la firma silenciosa con una clave/identidad comprometida — la entrada queda públicamente registrada.

**4.4** `--certificate-identity-regexp '.*'` acepta *cualquier* firmante. Escenario: un atacante que logra credenciales OIDC de *cualquier* cuenta (o su propio repo público) puede firmar una imagen maliciosa con el mismo Fulcio/Rekor; tu `verify` la aceptará como válida porque no exige que el firmante sea *tu* workflow. Verificar de verdad requiere fijar `--certificate-identity` a tu repo/workflow y `--certificate-oidc-issuer` a `https://token.actions.githubusercontent.com`. Verificar la firma sin verificar *la identidad del firmante* no aporta seguridad.

**4.5** El SBOM se genera una vez (parsear la imagen es lo caro) y luego cada consumidor (grype ahora, otro scanner después, la atestación) trabaja sobre el mismo `sbom.spdx.json`. Es más rápido, y sobre todo **reproducible y consistente**: todos escanean exactamente el mismo inventario, en lugar de re-analizar la imagen y arriesgar resultados divergentes por versiones distintas del analizador.

### Bloque 5 — Best practices y DORA

**5.1** Con `fail-fast: true` (default), si una celda de la matriz falla, GitHub **cancela** las demás celdas en curso — feedback rápido cuando cualquier fallo ya invalida el build. Con `fail-fast: false`, todas las celdas corren hasta el final aunque una falle — lo querés cuando necesitás el mapa completo de *qué* combinaciones fallan (p. ej. "¿falla solo en Go 1.21 o en las dos?"), típico en matrices de compatibilidad.

**5.2** `needs: [verify]` hace que `build-image` **no arranque** hasta que todos los jobs `verify` (todas las celdas de la matriz) terminen en éxito. Es fail-fast a nivel pipeline: no gastás tiempo ni recursos construyendo, empujando, escaneando y firmando una imagen a partir de código que ni siquiera pasó los tests. El gate de calidad está *antes* del trabajo caro.

**5.3** Un tag como `@v4` es mutable: el mantenedor (o quien comprometa su cuenta) puede reapuntar `v4` a un commit malicioso, y tu CI ejecutará ese código con acceso a tus secrets y a tu proceso de firma. Pinnear por SHA completo (`@a1b2c3...`) fija el código exacto y elimina ese vector de *supply chain attack* sobre la propia CI. Conecta con el Ejercicio 4: no sirve firmar el artefacto de salida si un step no confiable *dentro* del pipeline pudo alterarlo o robar la identidad de firma.

**5.4** Velocidad/throughput: **Deployment Frequency** y **Lead Time for Changes**. Estabilidad: **Change Failure Rate** y **Failed Deployment Recovery Time (MTTR)**. Medir solo velocidad incentiva desplegar rápido rompiendo cosas: subís la frecuencia a costa de la tasa de fallos y del tiempo de recuperación. Las cuatro juntas evitan ese incentivo perverso — un equipo de élite mejora throughput **y** estabilidad a la vez, no una a costa de la otra.

**5.5** Un *hermetic build* es aquel cuyo resultado depende **únicamente** de sus inputs declarados y pinneados (source commit, dependencias con hash en `go.sum`, imágenes base por digest, acciones por SHA), sin acceso a red no declarado ni a estado del runner. Anti-patrón que lo rompe: un step que hace `go get` de una dependencia *no pinneada* en tiempo de build, o que lee un archivo dejado por un job anterior en el runner. En cualquiera de esos casos el mismo commit puede producir artefactos distintos según *cuándo* y *dónde* corrió — que es exactamente la reproducibilidad por digest que construimos desde el Ejercicio 2 y sobre la que descansan la firma y la provenance del Ejercicio 4.

</details>

---

### Fuentes oficiales

- CNCF — *Cloud Native Platform Engineering Associate (CNPA) Curriculum*: https://github.com/cncf/curriculum
- GitHub Actions — *Workflow syntax, concurrency, permissions*: https://docs.github.com/actions
- Tekton — *Pipelines, Tasks, Workspaces*: https://tekton.dev/docs/pipelines/ · Catalog/Hub: https://hub.tekton.dev/
- Buildah: https://buildah.io/ · Kaniko: https://github.com/GoogleContainerTools/kaniko
- Distroless base images: https://github.com/GoogleContainerTools/distroless
- Sigstore / cosign (keyless, Fulcio, Rekor): https://docs.sigstore.dev/
- Anchore Syft (SBOM): https://github.com/anchore/syft · Grype: https://github.com/anchore/grype · Trivy: https://trivy.dev/
- SLSA (Supply-chain Levels for Software Artifacts): https://slsa.dev/
- Trunk Based Development: https://trunkbaseddevelopment.com/
- DORA — *DevOps metrics*: https://dora.dev/