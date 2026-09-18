# 701.3 — Gestión del código fuente

**LPI DevOps Tools Engineer — Examen 701-100, v2.0.0 · Tema 701: Ingeniería de software · Peso: 10**

---

## 1. El problema arquitectónico: el repositorio es el sistema de registro

Todas las demás etapas de una plataforma de entrega son una *derivación* del control de código fuente. La imagen de contenedor es una función de un commit. El manifiesto de Kubernetes aplicado en producción es una función de un commit. El SBOM, la atestación de procedencia, la respuesta de auditoría a "quién aprobó este cambio y cuándo" — todas son funciones de un commit. Si la capa de SCM es débil, nada aguas abajo puede ser más fuerte que ella, porque no se puede firmar, reproducir ni revertir aquello que no se puede direccionar.

Por eso la gestión del código fuente tiene un peso desproporcionado para un SRE. Las fallas no son "perdí mi trabajo"; son arquitectónicas:

| Clase de falla | Síntoma concreto en producción | Causa raíz en la capa de SCM |
|---|---|---|
| **Build irreproducible** | La imagen etiquetada `v2.4.1` no puede reconstruirse byte a byte; el tag fue movido | Tags mutables, sin tags anotados/firmados, sin `git describe` en el build |
| **Cambio no atribuible** | La revisión del incidente no puede determinar quién escribió una línea de configuración | Commits sin firmar, cuentas de servicio compartidas, historia reescrita en una rama compartida |
| **Exposición de secretos** | Un `kubeconfig` filtrado sigue siendo accesible en la historia durante años después de "borrar el archivo" | Git es append-only por diseño; borrar es un commit nuevo, no una eliminación |
| **Colapso de integración** | Doce ramas de larga vida, el merge lleva días, los conflictos semánticos pasan CI | Modelo de branching desajustado respecto al tamaño del equipo y la cadencia de despliegue |
| **Precipicio en el tiempo de clonado** | Un monorepo de 40 GB hace que cada job de CI gaste 6 minutos en `git clone` | Se traen historia completa + blobs completos cuando solo hace falta un árbol |
| **Deriva del estado deseado** | El clúster ejecuta algo que ningún commit describe | GitOps no aplicado; `kubectl apply` desde laptops |

La mecánica que sigue existe para hacer que cada una de esas filas sea imposible por construcción, no por disciplina.

---

## 2. El modelo de objetos: qué almacena Git realmente

Git es una base de datos de objetos direccionable por contenido con un índice con forma de sistema de archivos por encima. Entender los cuatro tipos de objeto es la diferencia entre usar Git y diagnosticarlo.

| Objeto | Contiene | Direccionado por | ¿Mutable? |
|---|---|---|---|
| **blob** | Bytes crudos del archivo. Sin nombre, sin modo, sin historia | Hash de `blob <len>\0<content>` | No |
| **tree** | Lista de entradas `(mode, type, hash, name)` — un directorio | Hash de sus entradas serializadas | No |
| **commit** | Un hash de tree, cero o más padres, autor, committer, mensaje, `gpgsig` opcional | Hash de la cabecera del commit + el mensaje | No |
| **tag** (anotado) | Puntero a un objeto + tagger + mensaje + firma opcional | Hash del objeto tag | No |

Todo lo demás — ramas, `HEAD`, refs de seguimiento remoto, el stash, las notas — es una *referencia*: un archivo de 41 bytes (o una línea en `packed-refs`) que contiene un hash. Las ramas son baratas porque una rama es un nombre de archivo que contiene un hash.

### 2.1 Comprobarlo en un repositorio vivo

```
$ git init --initial-branch=main /tmp/objmodel
Initialized empty Git repository in /tmp/objmodel/.git/

$ cd /tmp/objmodel
$ printf 'apiVersion: v1\n' > note.txt
$ git add note.txt
$ git commit -q -m 'chore: seed the object database'
$ git cat-file -p HEAD
tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904
author Ada Lovelace <ada@example.org> 1758153600 +0000
committer Ada Lovelace <ada@example.org> 1758153600 +0000

chore: seed the object database
```

Bajá un nivel, de commit a tree y de tree a blob:

```
$ git cat-file -p HEAD^{tree}
100644 blob 3f4e2b1a9c0d5e6f7a8b9c0d1e2f3a4b5c6d7e8f    note.txt

$ git cat-file -p 3f4e2b1a9c0d5e6f7a8b9c0d1e2f3a4b5c6d7e8f
apiVersion: v1

$ git cat-file -t 3f4e2b1a9c0d5e6f7a8b9c0d1e2f3a4b5c6d7e8f
blob
```

El hash no se asigna, se *calcula*. Reproducilo sin ayuda de Git:

```
$ printf 'blob 15\0apiVersion: v1\n' | sha1sum
3f4e2b1a9c0d5e6f7a8b9c0d1e2f3a4b5c6d7e8f  -
```

**Consecuencia arquitectónica:** contenido idéntico almacenado en mil directorios es un solo blob. Los renombres no se almacenan — Git registra dos trees e *infiere* el renombre en el momento de la lectura con una heurística de similitud (`git log --follow`, `diff.renames`). Por eso `git mv` es un envoltorio de conveniencia sobre `rm` + `add`, no una operación distinta.

### 2.2 Las tres áreas, y el índice como archivo real

```
$ git ls-files --stage
100644 3f4e2b1a9c0d5e6f7a8b9c0d1e2f3a4b5c6d7e8f 0    note.txt
```

El número de stage `0` significa "sin conflicto". Durante un conflicto de merge la misma ruta aparece tres veces, con stages `1` (ancestro común / base), `2` (ours), `3` (theirs):

```
$ git ls-files --stage -- deploy/values.yaml
100644 a1b2c3d4e5f60718293a4b5c6d7e8f9012345678 1    deploy/values.yaml
100644 b2c3d4e5f60718293a4b5c6d7e8f90123456789a 2    deploy/values.yaml
100644 c3d4e5f60718293a4b5c6d7e8f90123456789abc 3    deploy/values.yaml
```

Esta es la definición mecánica de un conflicto: el índice contiene tres versiones de una ruta y se niega a producir un tree. `git checkout --ours`/`--theirs` selecciona el stage 2 o el 3; `git add` colapsa al stage 0 y el merge puede completarse.

| Área | Ubicación física | Se puebla con | Se descarta con |
|---|---|---|---|
| Working tree | Archivos en disco | `git checkout` / `git switch` / `git restore` | `git restore <path>` |
| Índice (staging area) | `.git/index`, binario | `git add`, `git rm`, `git mv` | `git restore --staged <path>` |
| Base de objetos + refs | `.git/objects`, `.git/refs` | `git commit`, `git fetch` | `git gc` una vez inalcanzable |

### 2.3 Refs, HEAD y el reflog

```
$ cat .git/HEAD
ref: refs/heads/main

$ git symbolic-ref HEAD
refs/heads/main

$ git rev-parse HEAD
9c1f0a4d7b2e3a5c8d1f6b0e4a7c9d2f5b8e1a03

$ git for-each-ref --format='%(refname) %(objecttype) %(objectname:short)'
refs/heads/main commit 9c1f0a4
refs/remotes/origin/main commit 9c1f0a4
refs/tags/v2.4.1 tag 7d3b9e1
```

Un **HEAD desacoplado** (detached HEAD) es sencillamente `.git/HEAD` conteniendo un hash crudo en lugar de `ref: refs/heads/...`. Los commits hechos ahí no son alcanzables desde nada más que el reflog, y `git gc` terminará por borrarlos. Ese es todo el misterio.

El reflog es el diario local, por ref, de cada valor que una ref ha tenido — es lo que hace que casi toda operación destructiva de Git sea recuperable *localmente*, y **nunca se envía con push**:

```
$ git reflog show main --date=iso
9c1f0a4 main@{2026-09-17 11:04:22 +0000}: commit: feat: add readiness probe
1a2b3c4 main@{2026-09-17 10:51:07 +0000}: reset: moving to HEAD~2
5d6e7f8 main@{2026-09-17 10:12:44 +0000}: rebase (finish): refs/heads/main onto 8899aab
```

Expiración por defecto: 90 días para las entradas alcanzables (`gc.reflogExpire`), 30 días para las inalcanzables (`gc.reflogExpireUnreachable`).

### 2.4 SHA-1, SHA-256 e integridad

El uso de SHA-1 en Git fue endurecido con detección de colisiones (`sha1dc`) desde la 2.13 — una colisión fabricada al estilo SHAttered aborta la operación en vez de corromper silenciosamente la base de datos. Existe un formato de objetos SHA-256 y es usable, pero **no hay interoperabilidad entre un repositorio SHA-1 y uno SHA-256**; no se puede hacer push entre ellos.

```
$ git init --object-format=sha256 /tmp/sha256repo
Initialized empty Git repository in /tmp/sha256repo/.git/

$ git -C /tmp/sha256repo rev-parse --show-object-format
sha256
```

Tratá los repositorios SHA-256 como un experimento a futuro; no migres hoy un repositorio de plataforma compartido. En su lugar, forzá las verificaciones de integridad en la transferencia, que están desactivadas por defecto por rendimiento:

```
$ git config --global transfer.fsckObjects true
$ git config --global fetch.fsckObjects true
$ git config --system receive.fsckObjects true
```

---

## 3. Mecánica de integración: merge, rebase, y qué destruye cada uno

### 3.1 Fast-forward vs. three-way

Un **fast-forward** no es un merge: si `HEAD` es un ancestro del objetivo, Git mueve la ref. No se crea ningún objeto nuevo, no es posible ningún conflicto, y la existencia de la rama desaparece del grafo.

Un **merge a tres vías** calcula la base de merge (`git merge-base A B`), hace el diff base→ours y base→theirs, y los combina. Desde Git 2.34 la estrategia por defecto es **`ort`** ("Ostensibly Recursive's Twin"), una reescritura de `recursive` que es dramáticamente más rápida en árboles grandes y maneja mejor la detección de renombres y las historias entrecruzadas (múltiples bases de merge).

```
$ git merge-base --all main feature/probe
8899aabbccddeeff00112233445566778899aabb

$ git merge --no-ff feature/probe
Auto-merging deploy/values.yaml
CONFLICT (content): Merge conflict in deploy/values.yaml
Automatic merge failed; fix conflicts and then commit the result.

$ git status --short
UU deploy/values.yaml
M  deploy/deployment.yaml
```

Configurá un estilo de conflicto que muestre la *base*, para poder ver qué cambió cada lado en lugar de adivinar:

```
$ git config --global merge.conflictStyle zdiff3
```

Con `zdiff3` los marcadores llevan una sección de base:

```
<<<<<<< HEAD
  replicas: 6
||||||| 8899aab
  replicas: 3
=======
  replicas: 4
>>>>>>> feature/probe
```

Ahora la decisión es informada: el nuestro escaló 3→6, el de ellos escaló 3→4. Con el estilo `merge` por defecto solo verías 6 vs. 4 y no sabrías qué lado se movió.

### 3.2 Rebase: reproducir parches, crear objetos nuevos

`git rebase` toma los commits exclusivos de tu rama, calcula sus parches y los vuelve a aplicar sobre una base nueva. **Cada commit rebaseado es un objeto nuevo con un hash nuevo** — el tree puede ser idéntico, el padre no lo es. Por eso rebasear una rama que otros ya trajeron con pull es una caída en miniatura.

```
$ git rebase --onto origin/main HEAD~3 feature/probe
Successfully rebased and updated refs/heads/feature/probe.

$ git range-diff origin/main HEAD@{1} HEAD
1:  4f5a6b7 = 1:  a1b2c3d feat: add readiness probe
2:  6c7d8e9 ! 2:  b2c3d4e feat: expose /healthz
    @@ internal/server/health.go
     -   w.WriteHeader(http.StatusOK)
     +   w.WriteHeader(http.StatusNoContent)
3:  8e9f0a1 = 3:  c3d4e5f test: cover the probe path
```

`git range-diff` es la herramienta de revisión correcta después de un force-push: hace el diff de dos *series* de commits y muestra exactamente qué parches cambiaron, algo invisible para un diff común.

### 3.3 Tabla de compromisos: estrategias de integración

| Estrategia | Forma del grafo | Fidelidad de la historia | Bisectabilidad | Granularidad del revert | Segura en rama compartida | Mejor para |
|---|---|---|---|---|---|---|
| `merge --ff-only` | Lineal | Exacta | Excelente | Por commit | Sí | `main` protegida en flujo trunk-based |
| `merge --no-ff` | Burbujas de merge | Exacta + registra el punto de integración | Buena (`--first-parent`) | Feature completa (revertir el merge con `-m 1`) | Sí | Ramas de release, entornos con mucha auditoría |
| `rebase` y luego ff | Lineal | Reescrita (fechas, hashes, posiblemente semántica) | Excelente | Por commit | **No** | Ramas de feature privadas antes de la revisión |
| `merge --squash` | Lineal, un commit por feature | Con pérdida — los pasos intermedios desaparecen | Gruesa pero muy limpia | Feature completa | Sí | Repos con mucha rotación y commits WIP ruidosos |
| `cherry-pick` | Parches duplicados | Duplica contenido bajo hashes nuevos | Confusa (el mismo cambio, dos hashes) | Por pick | Sí | Backportear un hotfix a una rama de release |

Dos reglas operativas que se desprenden directamente de la mecánica:

1. **El rebase reescribe la historia; nunca rebasees una ref que otras personas traen con fetch.** Si tenés que hacerlo, usá `--force-with-lease --force-if-includes` para no poder pisar silenciosamente un commit que nunca viste:

```
$ git push --force-with-lease --force-if-includes origin feature/probe
To ssh://git@git.example.org/platform/api.git
 + 6c7d8e9...b2c3d4e feature/probe -> feature/probe (forced update)
```

El `--force` a secas sobrescribe incondicionalmente. `--force-with-lease` rechaza si la ref remota se movió desde tu último fetch. `--force-if-includes` (Git 2.30+) cierra el agujero restante donde un `git fetch` en segundo plano actualizó tu ref de seguimiento remoto sin que vos la hayas integrado.

2. **Enseñale a Git a reutilizar las resoluciones de conflictos** en rebases repetidos de ramas de larga vida:

```
$ git config --global rerere.enabled true
$ git config --global rerere.autoUpdate true
```

`rerere` registra el hunk del conflicto y su resolución bajo `.git/rr-cache/`; la próxima vez que aparezca el conflicto idéntico se resuelve automáticamente. Ahorra mucho tiempo en ramas de release — y es un riesgo si la primera resolución fue equivocada, ya que se reproducirá en silencio. `git rerere forget <path>` limpia una entrada.

---

## 4. Modelos de branching: elegir una topología, no una preferencia

| Modelo | Ramas de larga vida | Frecuencia de merge | Mecanismo de release | Aislamiento de features | Costo de un hotfix | Encaja en |
|---|---|---|---|---|---|---|
| **Trunk-based** | Solo `main` | Varias veces al día, ramas de < 24 h | Tag en `main` + promoción del artefacto | Feature flags | Trivial — commit en `main`, promover | CD, equipos de alta confianza, repos de plataforma |
| **GitHub Flow** | Solo `main` | Por PR | Deploy al mergear | Vida de la rama: horas–días | Igual que cualquier cambio | SaaS, versión única en producción |
| **GitLab Flow** | `main` + ramas de entorno (`staging`, `production`) | Solo merges hacia abajo | Merge `main`→`staging`→`production` | Rama + compuerta de entorno | Cherry-pick a `production` | Compuertas de promoción reguladas |
| **Git Flow** | `main`, `develop`, `release/*`, `hotfix/*` | Semanas | Estabilización en `release/*` y luego tag | Fuerte, de larga vida | `hotfix/*` dedicada + doble merge | Software distribuido/on-prem, muchas versiones soportadas |
| **Release train** | `main` + `release-X.Y` | Continuo a `main`, cherry-pick hacia atrás | Cortar una rama según calendario | Política de backports | Cherry-pick por release soportada | Proyectos al estilo Kubernetes |

**La variable decisiva no es el gusto del equipo, es cuántas versiones hay que soportar en producción simultáneamente.** Una versión → trunk-based. Muchas → necesitás ramas de release, y tenés que aceptar el impuesto del backport.

### 4.1 Conflictos semánticos y colas de merge

La falla que los modelos de branching rara vez abordan: dos PR pasan CI contra `main` cada uno, no chocan en ningún archivo, y rompen `main` cuando ambos aterrizan — uno renombró una función, el otro agregó un llamador. Un merge textual no puede verlo.

El arreglo mecánico es una **cola de merge**: serializar los candidatos, construir cada uno contra el resultado *especulado* de los que van delante, y hacer fast-forward de `main` solo cuando está en verde.

```yaml
name: ci
on:
  pull_request:
    branches:
      - main
  merge_group:
    types:
      - checks_requested
permissions:
  contents: read
concurrency:
  group: "ci-${{ github.ref }}"
  cancel-in-progress: true
jobs:
  verify:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout with full history
        uses: actions/checkout@v4
        with:
          fetch-depth: 0
          persist-credentials: false
      - name: Verify commit messages against Conventional Commits
        run: |
          base="${{ github.event.pull_request.base.sha }}"
          head="${{ github.event.pull_request.head.sha }}"
          if [ -z "$base" ]; then
            base="$(git rev-parse HEAD~1)"
            head="$(git rev-parse HEAD)"
          fi
          git log --format=%s "${base}..${head}" | while read -r subject; do
            echo "$subject" | grep -Eq '^(feat|fix|docs|chore|refactor|test|perf|build|ci)(\([a-z0-9-]+\))?!?: .+' \
              || { echo "non-conforming subject: $subject" >&2; exit 1; }
          done
      - name: Fail on merge conflict markers
        run: |
          if git grep -nE '^(<{7}|={7}|>{7})( |$)' -- . ':!docs/**'; then
            echo "conflict markers committed" >&2
            exit 1
          fi
      - name: Unit tests
        run: make test
```

Fijate en las dos decisiones de endurecimiento: `persist-credentials: false` mantiene el token del job fuera de `.git/config`, donde cualquier paso del build podría leerlo, y `fetch-depth: 0` se pide explícitamente porque los pasos que dependen de la historia (`git describe`, el linting de commits, los rangos de `git log`) se comportan mal en silencio bajo el clon superficial por defecto.

---

## 5. Topología del repositorio: monorepo vs. polyrepo, y las herramientas de escalado

| Dimensión | Monorepo | Polyrepo |
|---|---|---|
| Cambio atómico entre servicios | Un commit, una revisión | N PR, merge coordinado, ventana de carrera |
| Desfase de versiones de dependencias | Estructuralmente imposible (una versión de todo) | Estado normal; requiere un registry y pinning |
| Costo de clonado/CI | Crece con toda la organización; necesita clon parcial + sparse checkout | Naturalmente acotado |
| Control de acceso | Por ruta, requiere soporte de la forja (CODEOWNERS, reglas de ruta de GitLab) | A nivel de repositorio, simple y grueso |
| Radio de impacto de un `main` roto | Todos | Un equipo |
| Inversión en tooling requerida | Alta (grafo de build, detección de targets afectados) | Baja |
| Refactor cruzando fronteras | Barato | Caro (ciclos de deprecación) |

Un monorepo es una apuesta a que vas a invertir en tooling de build; un polyrepo es una apuesta a que vas a invertir en coordinación de releases. Ambas apuestas son pagables — un monorepo sin financiar es la falla común.

### 5.1 Hacer que un repositorio grande sea barato de clonar

Tres palancas independientes, combinables:

```
$ git clone --filter=blob:none --no-checkout ssh://git@git.example.org/platform/mono.git
Cloning into 'mono'...
remote: Enumerating objects: 918442, done.
remote: Total 918442 (delta 0), reused 0 (delta 0), pack-reused 918442
Receiving objects: 100% (918442/918442), 214.66 MiB | 31.22 MiB/s, done.
Resolving deltas: 100% (611930/611930), done.

$ cd mono
$ git sparse-checkout set --cone services/billing platform/lib
$ git checkout main
Updating files: 100% (1894/1894), done.
Your branch is up to date with 'origin/main'.

$ du -sh .git
248M    .git
```

| Técnica | Flag | Qué se omite | Costo cuando necesitás el dato | ¿Segura para CI? |
|---|---|---|---|---|
| Clon superficial | `--depth=1` | Toda la historia más allá de N commits | `git fetch --unshallow` (refetch completo) | Solo para jobs que nunca leen la historia |
| Clon parcial sin blobs | `--filter=blob:none` | El contenido de los archivos; se conservan trees y commits | Fetch perezoso por blob bajo demanda | Sí — el mejor valor por defecto para CI |
| Clon parcial sin trees | `--filter=tree:0` | Trees y blobs | Fetch perezoso, caro para `git log -- path` | Solo para builds de una sola vez |
| Sparse checkout | `sparse-checkout set --cone` | Archivos del working tree fuera del cono | Extender el cono | Sí |
| Rama única | `--single-branch` | Las refs de las demás ramas | `git remote set-branches` + fetch | Sí |

El servidor tiene que habilitar el clon parcial, o el filtro se ignora silenciosamente:

```
$ git config --system uploadpack.allowFilter true
$ git config --system uploadpack.allowAnySHA1InWant true
```

Acelerá el recorrido del grafo (`git log`, merge-base, `git describe`) con el commit-graph y el índice multi-pack, y dejá que Git los mantenga según una programación:

```
$ git commit-graph write --reachable --changed-paths
$ git multi-pack-index write
$ git maintenance start
$ systemctl --user list-timers git-maintenance@*
NEXT                        LEFT     LAST                        PASSED   UNIT                            ACTIVATES
Thu 2026-09-18 15:00:00 UTC 41min    Thu 2026-09-18 14:00:00 UTC 18min    git-maintenance@hourly.timer    git-maintenance@hourly.service
Fri 2026-09-19 00:00:00 UTC 9h       Thu 2026-09-18 00:00:00 UTC 14h      git-maintenance@daily.timer     git-maintenance@daily.service
```

### 5.2 Componer repositorios: submódulos, subtrees, registry de paquetes

| Enfoque | Dónde vive el código | Clon del consumidor | Pinning | Contribución upstream | Falla típica |
|---|---|---|---|---|---|
| **Submódulo** | Repo separado; el padre almacena un gitlink (una entrada de tree con modo `160000`) | Requiere `--recurse-submodules` | Commit exacto, siempre | Natural — commit en el submódulo | HEAD desacoplado dentro del submódulo; olvidarse del `--recurse`; commit fijado inalcanzable |
| **Subtree** | Vendorizado dentro del tree del padre | Un clon común alcanza | Por commit de importación | `git subtree push`, incómodo | Contaminación de la historia; contribuyentes que no saben que está vendorizado |
| **Registry de paquetes** | Artefacto, no fuente | Un clon común alcanza | Rango de versión o archivo lock | Ciclo de release | Desfase de versiones; superficie de cadena de suministro |
| **Directorio vendor** | Archivos copiados, sin vínculo con upstream | Un clon común alcanza | Manual | Ninguna | Divergencia silenciosa respecto de los arreglos de upstream |

Submódulos en la práctica — el ciclo de vida completo, incluidas las partes que se suelen saltear:

```
$ git submodule add -b release-1.29 ssh://git@git.example.org/platform/charts.git vendor/charts
Cloning into '/home/ada/mono/vendor/charts'...
done.

$ cat .gitmodules
[submodule "vendor/charts"]
	path = vendor/charts
	url = ssh://git@git.example.org/platform/charts.git
	branch = release-1.29

$ git ls-files --stage vendor/charts
160000 4d2f8a1b6c9e0f3a5b7d2e4f6a8c0b1d3e5f7a92 0	vendor/charts

$ git commit -q -m 'build: pin platform charts to release-1.29'
```

El modo `160000` es el gitlink: el commit del padre almacena *un hash de commit de otro repositorio*, nada más. Consecuencias: los objetos del submódulo no están en la base de objetos del padre, y si ese commit desaparece por un force-push upstream, cada commit del padre que lo referencia se vuelve inclonable.

```
$ git config --global submodule.recurse true
$ git clone --recurse-submodules ssh://git@git.example.org/platform/mono.git
$ git submodule update --init --recursive --depth 1
$ git submodule status
 4d2f8a1b6c9e0f3a5b7d2e4f6a8c0b1d3e5f7a92 vendor/charts (release-1.29-7-g4d2f8a1)
```

Un `-` al principio en `git submodule status` significa sin inicializar; un `+` significa que el commit del checkout difiere del que el padre tiene fijado — la causa más común de "en mi máquina funciona" en repos con submódulos.

Subtree, a modo de comparación — sin paso de clonado extra para los consumidores, a costa de una historia más pesada:

```
$ git subtree add --prefix=vendor/charts ssh://git@git.example.org/platform/charts.git release-1.29 --squash
git fetch ssh://git@git.example.org/platform/charts.git release-1.29
Added dir 'vendor/charts'

$ git subtree pull --prefix=vendor/charts ssh://git@git.example.org/platform/charts.git release-1.29 --squash
```

---

## 6. Integridad y procedencia: firma, protección, propiedad

El campo `author` de un commit sin firmar es una cadena de texto libre. `git commit --author="Linus Torvalds <torvalds@linux-foundation.org>"` no es un ataque, es un flag documentado. Por lo tanto, la atribución requiere criptografía.

### 6.1 Firma de commits basada en SSH (Git 2.34+)

Más simple de operar que GPG a escala de plataforma, porque el material de clave y el mecanismo de distribución ya existen:

```
$ git config --global gpg.format ssh
$ git config --global user.signingkey ~/.ssh/id_ed25519_signing.pub
$ git config --global commit.gpgsign true
$ git config --global tag.gpgsign true
$ git config --global gpg.ssh.allowedSignersFile ~/.config/git/allowed_signers

$ cat ~/.config/git/allowed_signers
ada@example.org namespaces="git" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ7Qm2v3Xk9Lp0Rr5Ty8Uu1Ii2Oo3Pp4Aa5Ss6Dd7Ff
grace@example.org namespaces="git" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK2Ww3Ee4Rr5Tt6Yy7Uu8Ii9Oo0Pp1Aa2Ss3Dd4Ff5Gg

$ git commit -q -m 'feat: enforce mTLS between gateway and billing'
$ git log --show-signature -1
commit e7a91c5d0b3f8a2e6c4d9b1f7a3e5c8d0b2f4a69
Good "git" signature for ada@example.org with ED25519 key SHA256:9Yk3...q1Zc
Author: Ada Lovelace <ada@example.org>
Date:   Thu Sep 18 14:12:03 2026 +0000

    feat: enforce mTLS between gateway and billing

$ git verify-commit HEAD && echo VERIFIED
Good "git" signature for ada@example.org with ED25519 key SHA256:9Yk3...q1Zc
VERIFIED
```

### 6.2 Tags: el único puntero de release correcto

| Tipo de tag | Objeto creado | ¿Se puede firmar? | ¿Lleva fecha/tagger? | `git describe` por defecto | Uso |
|---|---|---|---|---|---|
| Ligero | Ninguno — una ref a un commit | No | No | Necesita `--tags` | Marcadores locales |
| Anotado | Sí — un objeto tag | Sí | Sí | Sí | **Toda release** |

```
$ git tag -s -a v2.4.1 -m 'release: v2.4.1 — gateway mTLS'
$ git cat-file -p v2.4.1
object e7a91c5d0b3f8a2e6c4d9b1f7a3e5c8d0b2f4a69
type commit
tag v2.4.1
tagger Ada Lovelace <ada@example.org> 1758204723 +0000

release: v2.4.1 — gateway mTLS
-----BEGIN SSH SIGNATURE-----
U1NIU0lHAAAAAQAAADMAAAALc3NoLWVkMjU1MTkAAAAg...
-----END SSH SIGNATURE-----

$ git describe --tags --always --dirty
v2.4.1-0-ge7a91c5

$ git push origin v2.4.1
```

Los tags son mutables mediante force-push salvo que la forja lo prohíba. Protegelos del lado del servidor; un tag de release movido invalida todo artefacto construido a partir de él.

### 6.3 Propiedad y política de revisión como código

`CODEOWNERS` (GitHub, GitLab, Gitea — ponelo en `.github/`, `.gitlab/` o la raíz del repo):

```
# Fallback owner for everything not matched below.
*                               @platform/maintainers

# Kubernetes desired state requires both platform and the owning service team.
/deploy/**                      @platform/sre @platform/maintainers
/deploy/prod/**                 @platform/sre @security/appsec

# Anything that touches identity or crypto needs AppSec.
/internal/auth/**               @security/appsec
/internal/crypto/**             @security/appsec

# CI definitions are a privilege-escalation surface: treat them as code.
/.github/workflows/**           @platform/sre @security/appsec
/.gitlab-ci.yml                 @platform/sre @security/appsec
```

Combinalo con protección de ramas que exija, como mínimo: revisión obligatoria de los code owners, checks de estado obligatorios, historia lineal o commits de merge obligatorios (elegí uno y sé consistente), commits firmados, y nada de force-push ni borrado en `main` y `release/*`.

### 6.4 Archivos de higiene del repositorio

`.gitignore` — ignorá artefactos *generados*; nunca confíes en él para proteger secretos (no hace nada por los archivos ya trackeados):

```
# Build output
/bin/
/dist/
*.o
*.test

# Local environment — never commit
.env
.env.*
!.env.example
*.kubeconfig
*.pem
*.key

# Editor and OS noise
.idea/
.vscode/
.DS_Store
```

`.gitattributes` — normalizá los finales de línea, marcá los binarios y frená los diffs ruidosos. Este archivo es el arreglo para el vaivén de CRLF que hace que el PR de cada contribuyente de Windows toque 4.000 líneas:

```
* text=auto eol=lf
*.sh text eol=lf
*.bat text eol=crlf
*.png binary
*.qcow2 filter=lfs diff=lfs merge=lfs -text
go.sum merge=union
package-lock.json -diff linguist-generated=true
secrets.enc.yaml diff=sops
```

---

## 7. Aplicación de políticas: hooks a ambos lados del cable

| Hook | Lado | Se ejecuta cuando | ¿Puede bloquear? | Uso realista |
|---|---|---|---|---|
| `pre-commit` | Cliente | Antes del editor del mensaje de commit | Sí | Formateo, lint, escaneo de secretos |
| `prepare-commit-msg` | Cliente | Antes de que se abra el editor | No (edita la plantilla) | Inyectar el ID del ticket desde el nombre de la rama |
| `commit-msg` | Cliente | Después de escribir el mensaje | Sí | Chequeo de Conventional Commits |
| `pre-push` | Cliente | Antes de enviar los objetos | Sí | Bloquear pushes a refs protegidas, correr tests rápidos |
| `pre-receive` | **Servidor** | Una vez por push, antes de actualizar ninguna ref | Sí — rechaza atómicamente todo el push | El único lugar donde la política se aplica de verdad |
| `update` | **Servidor** | Una vez por ref | Sí — rechaza esa ref | Reglas por rama |
| `post-receive` | **Servidor** | Después de actualizar las refs | No | Disparar CI, notificar, replicar |

**Los hooks de cliente son un consejo; los hooks de servidor son política.** Cualquiera puede pasar `--no-verify`. Diseñá en consecuencia: hooks de cliente para feedback rápido, hooks de servidor (o reglas de push de la forja) para hacer cumplir.

Distribuí los hooks de cliente con un directorio trackeado en lugar de `.git/hooks`, que nunca se clona:

```
$ git config --local core.hooksPath .githooks
$ install -m 0755 /dev/stdin .githooks/pre-push <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
protected='^refs/heads/(main|release/.*)$'
while read -r _local_ref local_sha remote_ref _remote_sha; do
  if [[ "$remote_ref" =~ $protected && "$local_sha" != "0000000000000000000000000000000000000000" ]]; then
    echo "pre-push: direct push to ${remote_ref} is not allowed; open a merge request" >&2
    exit 1
  fi
done
exit 0
EOF
```

Un hook `pre-receive` que exige firmas, formato de mensaje y tamaño de archivo — la contraparte del lado del servidor:

```bash
#!/usr/bin/env bash
# .git/hooks/pre-receive on the bare repository
set -euo pipefail

ZERO='0000000000000000000000000000000000000000'
MAX_BLOB_BYTES=$((5 * 1024 * 1024))
status=0

while read -r oldrev newrev refname; do
  [ "$newrev" = "$ZERO" ] && continue            # branch deletion

  if [ "$oldrev" = "$ZERO" ]; then
    range="$newrev"
    revs=$(git rev-list "$newrev" --not --all)
  else
    range="${oldrev}..${newrev}"
    revs=$(git rev-list "$range")
  fi

  for rev in $revs; do
    subject=$(git log -1 --format=%s "$rev")
    if ! echo "$subject" | grep -Eq '^(feat|fix|docs|chore|refactor|test|perf|build|ci)(\([a-z0-9-]+\))?!?: .+'; then
      echo "reject ${rev:0:8}: subject does not follow Conventional Commits: $subject" >&2
      status=1
    fi

    if [ "$refname" = "refs/heads/main" ] && ! git verify-commit "$rev" >/dev/null 2>&1; then
      echo "reject ${rev:0:8}: unsigned commit on protected ref $refname" >&2
      status=1
    fi
  done

  while read -r objsize objpath; do
    if [ "$objsize" -gt "$MAX_BLOB_BYTES" ]; then
      echo "reject: $objpath is ${objsize} bytes; use Git LFS for files over ${MAX_BLOB_BYTES}" >&2
      status=1
    fi
  done < <(git rev-list --objects "$range" --not --all \
            | git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' \
            | awk '$1 == "blob" { print $3, $4 }')
done

exit "$status"
```

El push rechazado se ve así para quien desarrolla — notá que **ninguna ref se movió**, porque `pre-receive` es atómico para todo el push:

```
$ git push origin main
Enumerating objects: 9, done.
Counting objects: 100% (9/9), done.
Writing objects: 100% (5/5), 612 bytes | 612.00 KiB/s, done.
remote: reject 4a9f1c2e: subject does not follow Conventional Commits: wip
remote: reject: assets/demo.mp4 is 41943040 bytes; use Git LFS for files over 5242880
To ssh://git@git.example.org/platform/api.git
 ! [remote rejected] main -> main (pre-receive hook declined)
error: failed to push some refs to 'ssh://git@git.example.org/platform/api.git'
```

### 7.1 El framework `pre-commit`, configurado por completo

`.pre-commit-config.yaml` en la raíz del repositorio, instalado con `pre-commit install --install-hooks -t pre-commit -t commit-msg`:

```yaml
minimum_pre_commit_version: "3.5.0"
default_install_hook_types:
  - pre-commit
  - commit-msg
  - pre-push
fail_fast: false
repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v4.6.0
    hooks:
      - id: trailing-whitespace
      - id: end-of-file-fixer
      - id: check-merge-conflict
      - id: check-added-large-files
        args:
          - "--maxkb=5120"
      - id: check-yaml
        args:
          - "--allow-multiple-documents"
      - id: check-json
      - id: detect-private-key
      - id: no-commit-to-branch
        args:
          - "--branch=main"
          - "--pattern=^release/"
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.18.4
    hooks:
      - id: gitleaks
  - repo: https://github.com/adrienverge/yamllint
    rev: v1.35.1
    hooks:
      - id: yamllint
        args:
          - "--strict"
          - "-d"
          - "{extends: default, rules: {line-length: {max: 160}}}"
  - repo: https://github.com/compilerla/conventional-pre-commit
    rev: v3.4.0
    hooks:
      - id: conventional-pre-commit
        stages:
          - commit-msg
        args:
          - feat
          - fix
          - docs
          - chore
          - refactor
          - test
          - perf
          - build
          - ci
```

```
$ pre-commit run --all-files
trim trailing whitespace.................................................Passed
fix end of files.........................................................Passed
check for merge conflicts................................................Passed
check for added large files..............................................Passed
check yaml...............................................................Passed
check json...............................................................Passed
detect private key.......................................................Failed
- hook id: detect-private-key
- exit code: 1

deploy/prod/tls.yaml:12: BEGIN RSA PRIVATE KEY

yamllint.................................................................Passed
Conventional Commit......................................................Passed
```

---

## 8. El repositorio como estado deseado: cableado de GitOps

En una plataforma GitOps la capa de SCM deja de ser "donde quienes desarrollan guardan el código" y se convierte en la entrada del plano de control. Dos propiedades pasan a ser estructurales: **la revisión debe ser inmutable y direccionable** (fijar a un tag o a un digest, nunca a una rama en movimiento, para producción) y **el acceso de lectura del reconciliador debe ser de mínimo privilegio** (una deploy key con alcance de solo lectura, no un token personal).

`Application` de Argo CD, fijada a un tag firmado, con sync automatizado y corrección de deriva:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: billing-prod
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  source:
    repoURL: ssh://git@git.example.org/platform/deploy.git
    targetRevision: v2.4.1
    path: overlays/prod/billing
  destination:
    server: https://kubernetes.default.svc
    namespace: billing
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      allowEmpty: false
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
      - ApplyOutOfSyncOnly=true
    retry:
      limit: 5
      backoff:
        duration: 10s
        factor: 2
        maxDuration: 5m
  revisionHistoryLimit: 20
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas
```

El `AppProject` que restringe qué repositorios puede siquiera leer Argo CD — sin él, una única `Application` comprometida puede apuntar el clúster a cualquier repo:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: platform
  namespace: argocd
spec:
  description: "Platform-owned workloads, deployed only from the deploy repository"
  sourceRepos:
    - ssh://git@git.example.org/platform/deploy.git
  destinations:
    - server: https://kubernetes.default.svc
      namespace: billing
    - server: https://kubernetes.default.svc
      namespace: gateway
  clusterResourceWhitelist:
    - group: ""
      kind: Namespace
  namespaceResourceBlacklist:
    - group: rbac.authorization.k8s.io
      kind: ClusterRoleBinding
  signatureKeys:
    - keyID: 4AEE18F83AFDEB23
  roles:
    - name: read-only
      description: "Read-only access for on-call engineers"
      policies:
        - "p, proj:platform:read-only, applications, get, platform/*, allow"
```

`signatureKeys` es la parte que ata la sección 6 con la sección 8: Argo CD se negará a sincronizar una revisión cuyo commit no esté firmado por una clave listada. La firma de Git se convierte en una decisión de control de admisión.

El equivalente con Flux — la fuente `GitRepository`, separada de la reconciliación:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: platform-deploy
  namespace: flux-system
spec:
  interval: 1m
  url: ssh://git@git.example.org/platform/deploy.git
  ref:
    tag: v2.4.1
  secretRef:
    name: platform-deploy-key
  verify:
    mode: HEAD
    secretRef:
      name: platform-signing-keys
  ignore: |
    /*
    !/overlays
    !/base
```

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: billing-prod
  namespace: flux-system
spec:
  interval: 10m
  retryInterval: 1m
  timeout: 5m
  prune: true
  wait: true
  sourceRef:
    kind: GitRepository
    name: platform-deploy
  path: ./overlays/prod/billing
  targetNamespace: billing
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: billing-api
      namespace: billing
```

La deploy key de solo lectura, montada como `Secret` — notá el `stringData` con material de relleno; la clave real la inyecta SOPS o un operador de secretos externos, nunca se commitea:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: platform-deploy-key
  namespace: flux-system
type: Opaque
stringData:
  identity: "<ed25519 private key injected by the secrets operator>"
  identity.pub: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ7Qm2v3Xk9Lp0Rr5Ty8Uu1Ii2Oo3Pp4Aa5Ss6Dd7Ff flux@example.org"
  known_hosts: "git.example.org ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleHostKeyMaterialGoesHere0123456789"
```

### 8.1 Servidor Git autoalojado como infraestructura de plataforma

Una instancia de Gitea completa y desplegable — el punto es que el servicio de SCM está él mismo declarado, versionado y reconciliado como cualquier otra carga de trabajo. Un documento por manifiesto.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: scm
  labels:
    pod-security.kubernetes.io/enforce: restricted
```

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: gitea-config
  namespace: scm
data:
  app.ini: |
    APP_NAME = Example Platform SCM
    RUN_MODE = prod

    [server]
    PROTOCOL = http
    DOMAIN = git.example.org
    ROOT_URL = https://git.example.org/
    HTTP_PORT = 3000
    SSH_DOMAIN = git.example.org
    SSH_PORT = 22
    START_SSH_SERVER = true
    SSH_LISTEN_PORT = 2222
    LFS_START_SERVER = true

    [repository]
    DEFAULT_BRANCH = main
    DEFAULT_PUSH_CREATE_PRIVATE = true

    [repository.signing]
    INITIAL_COMMIT = never
    CRUD_ACTIONS = pubkey, twofa
    MERGES = pubkey, twofa

    [security]
    INSTALL_LOCK = true
    DISABLE_GIT_HOOKS = false

    [service]
    DISABLE_REGISTRATION = true
    REQUIRE_SIGNIN_VIEW = true

    [metrics]
    ENABLED = true

    [log]
    LEVEL = info
```

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: gitea
  namespace: scm
spec:
  serviceName: gitea
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: gitea
  template:
    metadata:
      labels:
        app.kubernetes.io/name: gitea
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "3000"
        prometheus.io/path: /metrics
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: gitea
          image: gitea/gitea:1.22.3-rootless
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 3000
            - name: ssh
              containerPort: 2222
          env:
            - name: GITEA_APP_INI
              value: /etc/gitea/conf/app.ini
            - name: GITEA__database__DB_TYPE
              value: postgres
            - name: GITEA__database__HOST
              value: "postgres.scm.svc.cluster.local:5432"
            - name: GITEA__database__NAME
              value: gitea
            - name: GITEA__database__USER
              valueFrom:
                secretKeyRef:
                  name: gitea-db
                  key: username
            - name: GITEA__database__PASSWD
              valueFrom:
                secretKeyRef:
                  name: gitea-db
                  key: password
          volumeMounts:
            - name: data
              mountPath: /var/lib/gitea
            - name: config
              mountPath: /etc/gitea/conf
              readOnly: true
            - name: tmp
              mountPath: /tmp
          resources:
            requests:
              cpu: 500m
              memory: 1Gi
            limits:
              cpu: "2"
              memory: 4Gi
          readinessProbe:
            httpGet:
              path: /api/healthz
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
              port: http
            initialDelaySeconds: 60
            periodSeconds: 20
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
      volumes:
        - name: config
          configMap:
            name: gitea-config
        - name: tmp
          emptyDir:
            sizeLimit: 2Gi
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes:
          - ReadWriteOnce
        storageClassName: fast-ssd
        resources:
          requests:
            storage: 200Gi
```

```yaml
apiVersion: v1
kind: Service
metadata:
  name: gitea
  namespace: scm
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: gitea
  ports:
    - name: http
      port: 3000
      targetPort: http
    - name: ssh
      port: 22
      targetPort: ssh
```

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: gitea
  namespace: scm
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/proxy-body-size: "1024m"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - git.example.org
      secretName: gitea-tls
  rules:
    - host: git.example.org
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: gitea
                port:
                  name: http
```

`proxy-body-size` no es cosmético: el límite de cuerpo por defecto de 1 MiB en NGINX Ingress rechaza cualquier push mayor a eso con un `HTTP 413` opaco, que a quien desarrolla le aparece como `RPC failed; HTTP 413`.

Alertas sobre el servicio de SCM, incluida la señal de crecimiento de almacenamiento que anticipa el incidente de "alguien commiteó una imagen de VM":

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: scm-platform
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: scm.rules
      rules:
        - alert: GitServerDown
          expr: up{job="gitea"} == 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Git server unreachable — all pipelines and GitOps reconciliation are blocked"
        - alert: GitRepositoryStorageGrowth
          expr: |
            (
              max by (instance) (gitea_repositories_size_bytes)
              -
              max by (instance) (gitea_repositories_size_bytes offset 7d)
            )
            /
            max by (instance) (gitea_repositories_size_bytes offset 7d)
            > 0.5
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: "Repository storage grew more than 50 percent in seven days; check for large binaries committed outside LFS"
        - alert: GitVolumeNearlyFull
          expr: |
            kubelet_volume_stats_available_bytes{namespace="scm"}
            /
            kubelet_volume_stats_capacity_bytes{namespace="scm"}
            < 0.15
          for: 15m
          labels:
            severity: critical
          annotations:
            summary: "SCM persistent volume below 15 percent free"
```

---

## 9. Binarios grandes: Git LFS

Git almacena para siempre todas las versiones de todos los archivos. Un binario de 200 MB modificado semanalmente agrega ~10 GB de packfile por año que todo clon debe descargar. LFS reemplaza el blob por un pequeño puntero de texto y mueve los bytes a un almacén separado.

```
$ git lfs install
Updated Git hooks.
Git LFS initialized.

$ git lfs track "*.qcow2" "*.tar.zst"
Tracking "*.qcow2"
Tracking "*.tar.zst"

$ cat .gitattributes
*.qcow2 filter=lfs diff=lfs merge=lfs -text
*.tar.zst filter=lfs diff=lfs merge=lfs -text

$ git add .gitattributes images/base.qcow2
$ git commit -q -m 'build: track VM images with LFS'
$ git show HEAD:images/base.qcow2
version https://git-lfs.github.com/spec/v1
oid sha256:6f1e3c9a8b2d4f7e0a1c5b9d3e6f8a2c4b7d0e3f6a9c2b5d8e1f4a7c0b3d6e9f
size 2147483648

$ git lfs ls-files
6f1e3c9a8b * images/base.qcow2
```

| Consideración | Comportamiento |
|---|---|
| Clonar sin LFS instalado | Obtenés archivos de puntero, no contenido — los builds fallan con "not a valid image" |
| CI | Necesita `lfs: true` en el checkout, o `git lfs pull` explícito |
| Soporte del servidor | La forja debe implementar la API de LFS; un repo bare por SSH solo no alcanza |
| Migración de la historia existente | `git lfs migrate import --include="*.qcow2" --everything` — **reescribe la historia**, con el mismo radio de impacto que una corrida de filter-repo |
| Borrado | Quitar el puntero no recupera almacenamiento en el servidor; los objetos LFS se recolectan por separado |

---

## 10. Secretos commiteados en la historia: detección, extirpación quirúrgica, rotación

**Primer principio: un secreto enviado a un repositorio compartido está comprometido. Rotalo. Quitarlo de la historia es limpieza, no remediación** — los clones, forks, cachés de CI y el propio almacenamiento de objetos colgantes de la forja pueden retenerlo.

Detectar:

```
$ gitleaks detect --source . --redact --report-format json --report-path /tmp/leaks.json
    ○
    │╲
    │ ○
    ○ ░
    ░    gitleaks

10:41AM INF 1483 commits scanned.
10:41AM INF scanned ~48.2 MB (2.19s)
10:41AM WRN leaks found: 2

$ git log --all --oneline -S 'AKIA' -- .
4a9f1c2 chore: local testing setup
b7e3d80 feat: initial terraform for the artifact bucket
```

`git log -S<string>` es el *pickaxe*: encuentra los commits donde cambió la cantidad de apariciones de la cadena — es decir, donde fue introducida o removida. `git log -G<regex>` busca sobre el texto del diff mismo. Ambas son las herramientas correctas para "cuándo apareció esta línea", y ambas son mucho más baratas que escanear checkouts.

Remover, usando `git-filter-repo` (el reemplazo mantenido del obsoleto `git filter-branch`):

```
$ git clone --mirror ssh://git@git.example.org/platform/api.git api-mirror.git
$ cd api-mirror.git
$ git filter-repo --invert-paths --path .env.production --path terraform/secrets.auto.tfvars
Parsed 1483 commits
New history written in 4.12 seconds; now repacking/cleaning...
Repacking your repo and cleaning out old unneeded objects
Completely finished after 9.87 seconds.

$ git filter-repo --replace-text <(printf 'AKIAIOSFODNN7EXAMPLE==>***REMOVED***\n')
Parsed 1483 commits
New history written in 3.64 seconds; now repacking/cleaning...
Completely finished after 8.91 seconds.

$ git count-objects -vH
count: 0
size: 0 bytes
in-pack: 21488
packs: 1
size-pack: 38.11 MiB
prune-packable: 0
garbage: 0
size-garbage: 0 bytes
```

Las consecuencias, que hay que comunicar antes de ejecutarlo:

1. **Cambia el hash de cada commit posterior al commit reescrito más antiguo.** Los tags, referencias de PR, registros de despliegue y salidas de `git describe` que nombraban hashes viejos ahora apuntan a nada.
2. Cada clon debe rehacerse. Alguien que haga pull y merge va a *reintroducir* la historia vieja.
3. `git-filter-repo` elimina deliberadamente el remoto `origin` después de reescribir, para que no puedas hacer push por accidente.
4. La forja sigue conservando objetos inalcanzables hasta que corra su propio GC — abrí un pedido de soporte/administración para purgarlos.

```
$ git remote add origin ssh://git@git.example.org/platform/api.git
$ git push --force --mirror origin
```

Después rotá: revocá la clave de AWS, reemitiá el token, volvé a sellar el archivo de SOPS y registrá el incidente.

---

## 11. Verificación y diagnóstico de fallas

### 11.1 Salud de la base de datos de objetos

```
$ git fsck --full --strict --unreachable --dangling
Checking object directories: 100% (256/256), done.
Checking objects: 100% (21488/21488), done.
dangling commit 3f1a9b7c0d2e5f8a1b4c7d0e3f6a9c2b5d8e1f40
dangling blob 7c2d5e8f1a4b7c0d3e6f9a2b5c8d1e4f7a0b3c69

$ git count-objects -vH
count: 1842
size: 12.44 MiB
in-pack: 21488
packs: 3
size-pack: 214.66 MiB
prune-packable: 118
garbage: 0
size-garbage: 0 bytes

$ git gc --prune=now
Enumerating objects: 23330, done.
Counting objects: 100% (23330/23330), done.
Delta compression using up to 8 threads
Compressing objects: 100% (6104/6104), done.
Writing objects: 100% (23330/23330), done.
Total 23330 (delta 15918), reused 21488 (delta 14700), pack-reused 0
```

"Dangling" es normal después de un rebase, reset o amend — es historia sin referenciar a la espera del GC, y es exactamente lo que se recupera. "Corrupt" no es normal; mirá la tabla de más abajo.

### 11.2 Encontrar el commit que rompió producción

`git bisect` es una búsqueda binaria sobre la historia. `git bisect run` la automatiza con un script cuyo código de salida decide: `0` = bueno, `1..124` = malo, `125` = saltear (no testeable), `>127` = abortar.

```
$ git bisect start
$ git bisect bad v2.4.1
$ git bisect good v2.3.0
Bisecting: 61 revisions left to test after this (roughly 6 steps)
[8f3c1a90b2d4e6f8a0c2e4f6a8c0e2f4a6c8e0f2] refactor: split the gateway config loader

$ git bisect run ./hack/repro-regression.sh
running './hack/repro-regression.sh'
Bisecting: 30 revisions left to test after this (roughly 5 steps)
...
d41c8e7b3a5f9c2e6b0d4f8a1c5e9b3d7f0a2c64 is the first bad commit
commit d41c8e7b3a5f9c2e6b0d4f8a1c5e9b3d7f0a2c64
Author: Grace Hopper <grace@example.org>
Date:   Mon Sep 14 09:22:41 2026 +0000

    fix: normalise upstream timeout units

 internal/gateway/config.go | 6 +++---
 1 file changed, 3 insertions(+), 3 deletions(-)
bisect found first bad commit

$ git bisect reset
Previous HEAD position was d41c8e7 fix: normalise upstream timeout units
Switched to branch 'main'
```

Análisis forense complementario:

```
$ git blame -L 88,96 --show-email -w -C internal/gateway/config.go
d41c8e7b (<grace@example.org> 2026-09-14 09:22:41 +0000 88)     timeout := cfg.UpstreamTimeout * time.Second
d41c8e7b (<grace@example.org> 2026-09-14 09:22:41 +0000 89)     if timeout <= 0 {

$ git log --first-parent --oneline --decorate main..origin/main
$ git log --format='%h %ad %an %s' --date=short --since='7 days ago' -- deploy/prod/
```

`-w` ignora los cambios de espacios en blanco y `-C` sigue el código movido entre archivos — sin ellos, `blame` con frecuencia le atribuye el cambio a un commit de reformateo en lugar de a quien escribió la lógica.

### 11.3 Recuperación tras operaciones destructivas

```
$ git reset --hard HEAD~5
HEAD is now at 1a2b3c4 chore: bump base image

$ git reflog
1a2b3c4 HEAD@{0}: reset: moving to HEAD~5
9c1f0a4 HEAD@{1}: commit: feat: add readiness probe
...

$ git reset --hard HEAD@{1}
HEAD is now at 9c1f0a4 feat: add readiness probe
```

Si la entrada del reflog ya no está pero el GC todavía no corrió, el commit sigue siendo un objeto colgante:

```
$ git fsck --lost-found
dangling commit 3f1a9b7c0d2e5f8a1b4c7d0e3f6a9c2b5d8e1f40

$ git show --stat 3f1a9b7
$ git branch recovered/probe 3f1a9b7
```

### 11.4 Tabla de diagnóstico: síntoma → mecanismo → resolución

| Mensaje / síntoma | Qué está pasando realmente | Resolución |
|---|---|---|
| `fatal: refusing to merge unrelated histories` | Las dos ramas no comparten base de merge (dos `git init` independientes) | `git merge --allow-unrelated-histories` — y verificá que sea lo que querés, y no un remoto mal agregado |
| `! [rejected] main -> main (non-fast-forward)` | El remoto tiene commits que vos no | `git fetch && git rebase origin/main` (o merge); nunca `--force` sobre una ref compartida |
| `! [remote rejected] (pre-receive hook declined)` | La política del servidor rechazó el push, de forma atómica | Leé las líneas `remote:`; arreglá localmente y volvé a hacer push |
| `You are in 'detached HEAD' state` | `.git/HEAD` contiene un hash, no una symref | `git switch -c <branch>` para conservar el trabajo, o `git switch -` para descartar la posición |
| `fatal: Not possible to fast-forward, aborting.` | `pull.ff=only` y las historias divergieron | `git pull --rebase` o `git pull --no-rebase` explícitamente |
| `error: object file .git/objects/ab/cdef… is empty` | Objeto suelto corrupto, en general por un apagado sucio o disco lleno | Borrá el archivo vacío, `git fsck`, y traé el objeto de otro clon: `git fetch <peer-clone> --tags` |
| `fatal: remote error: upload-pack: not our ref <sha>` | Un submódulo o un pin de CI referencia un commit que desapareció por force-push | Restaurá el commit upstream, o volvé a fijar el submódulo a un commit alcanzable |
| `shallow update not allowed` | Hacer push desde un clon `--depth` hacia un repo completo | `git fetch --unshallow` antes de hacer push |
| Todos los archivos aparecen como modificados después del checkout | Desajuste de normalización CRLF/LF | Agregá `* text=auto eol=lf` a `.gitattributes`, después `git add --renormalize .` |
| Un archivo aparece dos veces con distinta capitalización | Un sistema de archivos insensible a mayúsculas (macOS/Windows) colapsó dos rutas | `git config core.ignorecase true` localmente; arreglalo quitando una de las rutas desde un host sensible a mayúsculas |
| Los archivos de LFS son blobs de texto chicos | El filtro de LFS no está instalado en ese entorno | `git lfs install && git lfs pull`; en CI poné `lfs: true` en el checkout |
| `RPC failed; curl 92 HTTP/2 stream … / HTTP 413` | Límite de tamaño de cuerpo del proxy o del ingress en un push grande | Subí `proxy-body-size`, o hacé push por SSH; `git config http.postBuffer 524288000` como paliativo |
| El clon lleva minutos en cada job de CI | Se traen historia completa + blobs | `--filter=blob:none` + sparse checkout; `--depth=1` solo si no se lee la historia |
| El directorio `.git` crece sin límite | Objetos sueltos nunca empaquetados, o binarios grandes en la historia | `git maintenance start`; auditá con `git rev-list --objects --all \| git cat-file --batch-check` y mové los binarios a LFS |
| Los commits aparecen desordenados en `git log` | `--date-order` vs. fecha de autoría; o desfase de reloj del committer | Usá `git log --date-order` / `--topo-order`; arreglá NTP en el host que falla |
| Un conflicto resuelto reaparece resuelto *mal* | `rerere` reprodujo una resolución cacheada incorrecta | `git rerere forget <path>`, y resolvelo de nuevo |

### 11.5 Una rutina de verificación que vale la pena automatizar

```
$ git fsck --full --strict
$ git count-objects -vH
$ git verify-commit HEAD
$ git verify-tag "$(git describe --tags --abbrev=0)"
$ git log --oneline --no-merges origin/main..HEAD
$ git diff --stat origin/main...HEAD
$ git grep -nE '^(<{7}|={7}|>{7})( |$)' -- . || echo 'no conflict markers'
$ git ls-files -z | xargs -0 -n1 -I{} sh -c 'test $(git cat-file -s :{} 2>/dev/null || echo 0) -lt 5242880 || echo "large: {}"'
```

Tres puntos (`origin/main...HEAD`) en `git diff` significa "los cambios en HEAD desde la base de merge" — el diff que ve quien revisa. Dos puntos significa "la diferencia entre los dos extremos", que incluye invertidos los cambios hechos en `origin/main`. Elegir el equivocado es el origen de los diffs de PR que parecen revertir el trabajo de otras personas.

---

## 12. Referencia de comandos, agrupada por mecanismo

| Asunto | Comandos |
|---|---|
| Crear / obtener | `git init [--bare] [--initial-branch=main] [--object-format=sha256]`, `git clone [--depth] [--filter] [--recurse-submodules] [--single-branch]` |
| Inspeccionar el estado | `git status [--short] [--branch]`, `git diff [--staged] [--stat] [A...B]`, `git show`, `git log [--oneline] [--graph] [--first-parent] [-S] [-G] [--follow]`, `git blame [-L] [-w] [-C]` |
| Preparar y registrar | `git add [-p] [--renormalize]`, `git rm [--cached]`, `git mv`, `git commit [-s] [-S] [--amend] [--fixup]`, `git restore [--staged]` |
| Ramas y posición | `git branch [-a] [-m] [--merged]`, `git switch [-c] [--detach]`, `git checkout`, `git worktree add`, `git tag [-a] [-s] [-d]` |
| Integrar | `git merge [--no-ff] [--ff-only] [--squash] [-s ort]`, `git rebase [-i] [--onto] [--autosquash]`, `git cherry-pick [-x]`, `git revert [-m 1]`, `git range-diff` |
| Intercambiar | `git remote [-v] [add] [set-url]`, `git fetch [--prune] [--unshallow]`, `git pull [--rebase] [--ff-only]`, `git push [--tags] [--force-with-lease] [--force-if-includes] [--mirror]` |
| Deshacer | `git reset [--soft|--mixed|--hard]`, `git restore`, `git revert`, `git reflog`, `git stash [push -u] [list] [pop] [drop]` |
| Composición | `git submodule [add] [update --init --recursive] [status] [sync]`, `git subtree [add] [pull] [push]`, `git lfs [install] [track] [ls-files] [migrate]` |
| Forense | `git bisect [start] [good] [bad] [run] [reset]`, `git fsck [--lost-found]`, `git rev-list --objects --all`, `git cat-file [-t|-s|-p|--batch-check]`, `git hash-object`, `git ls-tree`, `git ls-files --stage`, `git verify-pack -v` |
| Mantenimiento | `git gc [--prune=now]`, `git repack -adb`, `git commit-graph write --reachable`, `git multi-pack-index write`, `git maintenance [start|run]`, `git count-objects -vH` |
| Procedencia | `git commit -S`, `git tag -s`, `git verify-commit`, `git verify-tag`, `git log --show-signature`, `git notes` |

---

## Referencias

- LPI — DevOps Tools Engineer, objetivos del examen 701 (v2.0): https://www.lpi.org/our-certifications/exam-701-objectives/
- Git — Manual de referencia (todos los comandos): https://git-scm.com/docs
- Git — libro Pro Git, "Git Internals": https://git-scm.com/book/en/v2/Git-Internals-Plumbing-and-Porcelain
- Git — `git-merge` y estrategias de merge (`ort`, `octopus`, `ours`): https://git-scm.com/docs/git-merge
- Git — `git-rebase`: https://git-scm.com/docs/git-rebase
- Git — `git-rerere`: https://git-scm.com/docs/git-rerere
- Git — `git-bisect`: https://git-scm.com/docs/git-bisect
- Git — `git-submodule`: https://git-scm.com/docs/git-submodule
- Git — `gitattributes(5)`: https://git-scm.com/docs/gitattributes
- Git — `gitignore(5)`: https://git-scm.com/docs/gitignore
- Git — `githooks(5)`: https://git-scm.com/docs/githooks
- Git — `git-maintenance`: https://git-scm.com/docs/git-maintenance
- Git — `git-config` (`transfer.fsckObjects`, `uploadpack.allowFilter`, `gpg.ssh.allowedSignersFile`): https://git-scm.com/docs/git-config
- Git — documentación de diseño del clon parcial: https://git-scm.com/docs/partial-clone
- Git — `git-sparse-checkout`: https://git-scm.com/docs/git-sparse-checkout
- Git — transición de la función de hash (SHA-256): https://git-scm.com/docs/hash-function-transition
- Git — aviso de deprecación de `git-filter-branch` y alternativas: https://git-scm.com/docs/git-filter-branch
- git-filter-repo — repositorio upstream y manual de uso: https://github.com/newren/git-filter-repo
- Git LFS — especificación y documentación: https://github.com/git-lfs/git-lfs/tree/main/docs
- GitHub Docs — Acerca de las ramas protegidas: https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches
- GitHub Docs — Acerca de los code owners: https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners
- GitHub Docs — Cola de merge: https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue
- GitLab Docs — GitLab Flow: https://docs.gitlab.com/ee/topics/gitlab_flow.html
- GitLab Docs — Ramas protegidas: https://docs.gitlab.com/ee/user/project/protected_branches.html
- Conventional Commits 1.0.0: https://www.conventionalcommits.org/en/v1.0.0/
- pre-commit — documentación del framework: https://pre-commit.com/
- Gitleaks — documentación: https://github.com/gitleaks/gitleaks
- Argo CD — especificación de Application y verificación de firmas GnuPG: https://argo-cd.readthedocs.io/en/stable/user-guide/gpg-verification/
- Argo CD — Projects: https://argo-cd.readthedocs.io/en/stable/user-guide/projects/
- Flux — API GitRepository: https://fluxcd.io/flux/components/source/gitrepositories/
- Flux — API Kustomization: https://fluxcd.io/flux/components/kustomize/kustomizations/
- OpenGitOps — Principios v1.0.0: https://opengitops.dev/
- Gitea — hoja de referencia de configuración: https://docs.gitea.com/administration/config-cheat-sheet
- Sigstore — Gitsign, firma de commits de Git sin claves: https://docs.sigstore.dev/cosign/signing/gitsign/