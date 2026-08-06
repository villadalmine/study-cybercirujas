# Guía de Preparación para el Examen e Ingeniería de Producción: LPI 050-100
## Tema 6.2: Source Code Management (Peso: 7.5)

### Fuentes de Referencia y Documentación Oficial
- [LPI Open Source Essentials Certification Overview](https://www.lpi.org/our-certifications/open-source-essentials-overview/)
- [LPI Open Source Essentials Official Objectives (Topic 056.2)](https://wiki.lpi.org/wiki/Open_Source_Essentials_Objectives_V1.0)
- [Official Git Documentation & Core Architecture Specifications](https://git-scm.com/doc)

---

## Visión General Técnica y Fundamentos de Arquitectura

Los sistemas de Source Code Management (SCM) son la base operativa central de la ingeniería de software moderna, SRE y los ecosistemas Cloud-Native DevOps. En los flujos de trabajo de infraestructura enterprise y open-source, SCM permite el desarrollo concurrente, la auditabilidad, el control de versiones inmutable, los pipelines de integración continua (CI/CD) y la recuperación ante desastres.

### Sistemas SCM Centralizados vs. Distribuidos

| Característica / Arquitectura | Centralized SCM (CSCM) (ej., Subversion / SVN) | Distributed SCM (DSCM) (ej., Git) |
| :--- | :--- | :--- |
| **Modelo de Repositorio** | Un único servidor central mantiene el historial completo de revisiones. Los clientes locales retienen únicamente una copia de trabajo (working copy). | Cada cliente mantiene un clon completo de la base de datos de objetos y del DAG del historial de revisiones. |
| **Dependencia de Red** | Requerida para commits, diffs, inspección de historial y operaciones de branching. | Los commits, consultas de historial, branches y diffs se ejecutan localmente fuera de línea (offline). La red solo se utiliza para la sincronización (`push`/`fetch`). |
| **Punto Único de Falla** | La caída del servidor central detiene todas las operaciones de control de versiones y representa un riesgo de pérdida total de datos si no cuenta con respaldo. | Resiliencia descentralizada; cada peer local actúa como un respaldo completo de la estructura del repositorio canónico. |
| **Rendimiento de Branching** | Costosa copia de directorios o manipulación de metadatos del lado del servidor; lento sobre WANs de alta latencia. | Manipulación de referencias casi instantánea (actualizaciones de punteros `O(1)` que apuntan a hashes SHA de commit inmutables). |

### Arquitectura Interna de Almacenamiento de Objetos de Git

Git es una base de datos de objetos clave-valor direccionable por contenido almacenada bajo `.git/objects/`. Los objetos se convierten en hash utilizando SHA-1 estándar (40 caracteres hexadecimales) o SHA-256 (64 caracteres hexadecimales) y se comprimen a través de `zlib`.

```
                    +------------------------------------+
                    |        Commit Object               |
                    | Hash: e4b2c1...                    |
                    |  - tree: 8a3f91...                 |
                    |  - parent: 12d7a4...               |
                    |  - author: Dev <dev@example.com>   |
                    |  - message: "Feat: Add API spec"   |
                    +-----------------+------------------+
                                      |
                                      v
                    +------------------------------------+
                    |         Tree Object                |
                    | Hash: 8a3f91...                    |
                    |  - 100644 blob c23a10... README.md |
                    |  - 040000 tree b91e03... src       |
                    +--------+------------------+--------+
                             |                  |
                             v                  v
          +----------------------+   +----------------------+
          |     Blob Object      |   |     Tree Object      |
          | Hash: c23a10...      |   | Hash: b91e03...      |
          | Content: "# Project" |   |  - 100644 blob ...   |
          +----------------------+   +----------------------+
```

1. **Blob (`blob`)**: Almacena el contenido del archivo en bruto (binario o texto). No almacena metadatos (nombre de archivo, permisos, marcas de tiempo).
2. **Tree (`tree`)**: Representa una capa de directorio. Mapea nombres de archivo, flags de modo (ej., `100644` archivo estándar, `100755` ejecutable) y hashes hijos (blobs o trees anidados).
3. **Commit (`commit`)**: Apunta a un hash de tree de directorio de nivel superior, registra el hash(es) del commit padre, las identidades de autor/committer, marcas de tiempo Unix y el mensaje de log.
4. **Annotated Tag (`tag`)**: Un objeto explícito que apunta directamente a un hash de commit específico, conteniendo metadatos del tagger, firma y mensaje.

---

## Lab Block 1: Arquitectura y Mecánica Interna del Git Object Store

En este laboratorio, inicializarás manualmente un repositorio, inspeccionarás el diseño de directorio de metadatos de bajo nivel, crearás objetos Git en bruto directamente dentro de la base de datos clave-valor y reconstruirás un commit sin invocar comandos estándar de alto nivel (Porcelain wrapper).

### Pasos Guiados Prácticos

1. Creá un directorio de trabajo e inicializá un nuevo repositorio Git:
```bash
mkdir -p ~/scm-internals-lab && cd ~/scm-internals-lab
git init
```
**Salida Esperada:**
```text
Initialized empty Git repository in /home/user/scm-internals-lab/.git/
```

2. Inspeccioná la arquitectura de almacenamiento de metadatos en `.git`:
```bash
ls -la .git/
```
**Salida Esperada:**
```text
total 32
drwxr-rf- 7 user user 4096 Aug  6 19:30 .
drwxr-rf- 3 user user 4096 Aug  6 19:30 ..
-rw-r--r-- 1 user user   23 Aug  6 19:30 HEAD
-rw-r--r-- 1 user user  130 Aug  6 19:30 config
-rw-r--r-- 1 user user   73 Aug  6 19:30 description
drwxr-rf- 2 user user 4096 Aug  6 19:30 hooks
drwxr-rf- 2 user user 4096 Aug  6 19:30 info
drwxr-rf- 4 user user 4096 Aug  6 19:30 objects
drwxr-rf- 4 user user 4096 Aug  6 19:30 refs
```

3. Generá un blob de contenido directamente en la base de datos de objetos usando `git hash-object`:
```bash
BLOB_SHA=$(echo "Production Platform Config v1" | git hash-object -w --stdin)
echo "Generated Blob SHA: ${BLOB_SHA}"
```
**Salida Esperada:**
```text
Generated Blob SHA: cb12803f27ae55734df2dd93b8aa9c3c0422c544
```

4. Verificá cómo Git almacena este objeto comprimido en disco bajo `.git/objects/`:
```bash
ls -la .git/objects/${BLOB_SHA:0:2}/
```
**Salida Esperada:**
```text
total 12
drwxr-rf- 2 user user 4096 Aug  6 19:31 .
drwxr-rf- 4 user user 4096 Aug  6 19:31 ..
-r--r--r-- 1 user user   51 Aug  6 19:31 12803f27ae55734df2dd93b8aa9c3c0422c544
```

5. Inspeccioná el tipo de objeto y los contenidos descomprimidos usando el comando Plumbing `git cat-file`:
```bash
git cat-file -t ${BLOB_SHA}
git cat-file -p ${BLOB_SHA}
```
**Salida Esperada:**
```text
blob
Production Platform Config v1
```

6. Prepará (stage) manualmente el objeto en el buffer de index (`.git/index`) usando `git update-index`:
```bash
git update-index --add --cacheinfo 100644 ${BLOB_SHA} config.txt
git ls-files -s
```
**Salida Esperada:**
```text
100644 cb12803f27ae55734df2dd93b8aa9c3c0422c544 0	config.txt
```

7. Escribí el estado del index en un objeto Tree y capturá su SHA de tree:
```bash
TREE_SHA=$(git write-tree)
echo "Written Tree SHA: ${TREE_SHA}"
git cat-file -p ${TREE_SHA}
```
**Salida Esperada:**
```text
Written Tree SHA: d3542cfb8c56c2d1b7dfb3d2bbf40adcd023ae81
100644 blob cb12803f27ae55734df2dd93b8aa9c3c0422c544	config.txt
```

8. Creá un objeto de commit inicial haciendo referencia a este hash de tree:
```bash
COMMIT_SHA=$(echo "Initial production config commit" | git commit-tree ${TREE_SHA})
echo "Written Commit SHA: ${COMMIT_SHA}"
git cat-file -p ${COMMIT_SHA}
```
**Salida Esperada:**
```text
Written Commit SHA: 8f420a811c7694931a788b776bd3114cf60d3d52
tree d3542cfb8c56c2d1b7dfb3d2bbf40adcd023ae81
author SRE Lead <sre@example.com> 1754518315 -0400
committer SRE Lead <sre@example.com> 1754518315 -0400

Initial production config commit
```

9. Actualizá la referencia del branch por defecto (`refs/heads/main`) para que apunte a este nuevo hash de commit:
```bash
git update-ref refs/heads/main ${COMMIT_SHA}
git symbolic-ref HEAD refs/heads/main
git log -n 1
```
**Salida Esperada:**
```text
commit 8f420a811c7694931a788b776bd3114cf60d3d52 (HEAD -> main)
Author: SRE Lead <sre@example.com>
Date:   Thu Aug 6 19:31:55 2026 -0400

    Initial production config commit
```

---

### Preguntas de Verificación (Lab Block 1)

**Pregunta 1.1:** Un desarrollador crea dos archivos separados llamados `app-dev.env` y `app-prod.env` en diferentes subdirectorios. Ambos archivos contienen exactamente la misma cadena de contenido: `DB_PORT=5432`. ¿Cuántos objetos blob creará Git en `.git/objects/`?
- A) 2 objetos blob, porque los nombres de archivo y rutas de carpeta difieren.
- B) 1 objeto blob, porque Git calcula el hash SHA basándose únicamente en el encabezado del contenido y los bytes de la carga útil (payload).
- C) 2 objetos blob, porque los permisos y las rutas de directorio están embebidos en el encabezado del blob.
- D) 0 objetos blob, porque los archivos en staging se almacenan en `.git/index` únicamente hasta que se realiza el commit.

**Pregunta 1.2:** ¿Qué archivo dentro de `.git/` determina la referencia del branch de trabajo activo?
- A) `.git/config`
- B) `.git/refs/heads/main`
- C) `.git/HEAD`
- D) `.git/index`

---

## Lab Block 2: Ciclo de Vida de Working Directory, Index/Staging y Arquitectura Ignore

Git opera en un **Modelo de Tres Estados**:
1. **Working Directory**: El sistema de archivos sandbox local donde se editan activamente los archivos.
2. **Staging Area (Index)**: Un archivo binario (`.git/index`) que lista rutas de archivos, permisos y hashes de objetos preparando el estado preciso del próximo commit.
3. **Git Repository (Object Store)**: La base de datos de historial permanente e inmutable que almacena los commits, trees y blobs en el DAG.

```
+------------------+      git add       +------------------+     git commit     +------------------+
|                  | -----------------> |                  | -----------------> |                  |
| Working Directory|                    | Staging Area     |                    | Git Repository   |
| (Sandbox Files)  | <----------------- | (Binary Index)   | <----------------- | (Object Database)|
+------------------+     git checkout   +------------------+     git reset      +------------------+
```

### Pasos Guiados Prácticos

1. Creá archivos de trabajo que representen código fuente de microservicios, logs y secretos confidenciales:
```bash
cd ~/scm-internals-lab
echo "package main" > main.go
echo "PORT=8080" > .env
mkdir -p logs && echo "runtime error log" > logs/app.log
```

2. Configurá patrones avanzados de ignorado de archivos a través de `.gitignore`:
```bash
cat << 'EOF' > .gitignore
# Ignore all environment secret files
*.env

# Ignore all contents of logs directory
logs/

# Exception: keep logs/keep.me directory placeholder
!logs/keep.me
EOF
touch logs/keep.me
```

3. Consultá el estado de los archivos rastreados (tracked), no rastreados (untracked) e ignorados usando la flag de estado Plumbing `git status --short`:
```bash
git status --short --branch
```
**Salida Esperada:**
```text
## main
?? .gitignore
?? main.go
```

4. Validá por qué `.env` y `logs/app.log` fueron ignorados usando `git check-ignore`:
```bash
git check-ignore -v .env logs/app.log logs/keep.me
```
**Salida Esperada:**
```text
.gitignore:2:*.env	.env
.gitignore:5:logs/	logs/app.log
```

5. Prepará (stage) los archivos de la base de código dentro de la base de datos Index:
```bash
git add main.go .gitignore logs/keep.me
git ls-files -s
```
**Salida Esperada:**
```text
100644 1e0062b8813a89052b947a1610e74f1b203c9d74 0	.gitignore
100644 e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 0	logs/keep.me
100644 b62cb174e2d3e1208a0d92233f2a89849206d203 0	main.go
```

6. Modificá `main.go` en el directorio de trabajo para observar la divergencia de estado entre Working Directory, Index y HEAD:
```bash
echo 'func main() { println("Service Running") }' >> main.go
git diff
```
**Salida Esperada:**
```text
diff --git a/main.go b/main.go
index b62cb17..5d10b77 100644
--- a/main.go
+++ b/main.go
@@ -1 +1,2 @@
 package main
+func main() { println("Service Running") }
```

7. Inspeccioná las diferencias entre el Index preparado (Staged Index) y el commit HEAD actual:
```bash
git diff --staged
```
**Salida Esperada:**
```text
diff --git a/.gitignore b/.gitignore
new file mode 100644
index 0000000..1e0062b
--- /dev/null
+++ b/.gitignore
@@ -0,0 +1,8 @@
+# Ignore all environment secret files
+*.env
+
+# Ignore all contents of logs directory
+logs/
+
+# Exception: keep logs/keep.me directory placeholder
+!logs/keep.me
diff --git a/logs/keep.me b/logs/keep.me
new file mode 100644
index 0000000..e69de29
diff --git a/main.go b/main.go
index 0000000..b62cb17
--- /dev/null
+++ b/main.go
@@ -0,0 +1 @@
+package main
```

8. Realizá el commit de los cambios preparados para formar un segundo nodo de commit en el DAG:
```bash
git commit -m "Feat: Add core app entrypoint and ignore rules"
```
**Salida Esperada:**
```text
[main 4f1a92e] Feat: Add core app entrypoint and ignore rules
 3 files changed, 10 insertions(+)
 create mode 100644 .gitignore
 create mode 100644 logs/keep.me
 create mode 100644 main.go
```

---

### Preguntas de Verificación (Lab Block 2)

**Pregunta 2.1:** ¿Cuál es el efecto operativo exacto del comando `git diff --staged` (sinónimo de `git diff --cached`)?
- A) Compara las diferencias entre el Working Directory y el HEAD del Git Repository local.
- B) Compara las diferencias entre el Staging Area (Index) y el último commit (`HEAD`).
- C) Compara las diferencias entre el `HEAD` del branch local y el branch de rastreo remoto (remote tracking branch).
- D) Verifica las ediciones no confirmadas (uncommitted) del árbol de trabajo contra los archivos no rastreados.

**Pregunta 2.2:** Un ingeniero de sistemas ejecuta `git add .` después de crear un archivo confidencial `db_pass.key`. Sin embargo, `.gitignore` ya contiene `*.key`. ¿Qué sucede?
- A) Git anula el `.gitignore` y prepara (stages) `db_pass.key` de todos modos.
- B) Git ignora `db_pass.key` e imprime un error fatal abortando todo el comando.
- C) Git omite de forma segura `db_pass.key` sin prepararlo (staging), mientras prepara los otros archivos modificados válidos.
- D) Git mueve `db_pass.key` a `.git/lost-found/`.

---

## Lab Block 3: Branching, Mecánica de Merging, Tagging y Flujos de Trabajo Remote Fork

Los branches de Git son punteros ligeros a hashes de commit específicos de 40 caracteres en `.git/refs/heads/`.
El proceso de merging integra historiales de commit distintos:
- **Fast-Forward Merge**: Si el branch destino no tiene commits divergentes con respecto al branch origen, Git simplemente mueve el puntero de la referencia hacia adelante (operación `O(1)`).
- **3-Way Merge**: Si ambos branches divergieron, Git calcula un commit ancestro común, evalúa las ediciones de ambos lados y genera un nuevo **Merge Commit** sintético con dos hashes padre.

```
Fast-Forward Merge:
main:    C1 ---> C2
                  \
feature:           C3 ---> C4  (main pointer simply advances to C4)

3-Way Merge:
main:    C1 ---> C2 ---------> C5 (Merge Commit: Parents C2, C4)
                  \           /
feature:           C3 ---> C4/
```

### Pasos Guiados Prácticos

1. Creá y cambiate a un branch de característica llamado `feature/auth`:
```bash
cd ~/scm-internals-lab
git checkout -b feature/auth
```
**Salida Esperada:**
```text
Switched to a new branch 'feature/auth'
```

2. Inspeccioná el archivo de referencia generado dentro de `.git/refs/heads/`:
```bash
cat .git/refs/heads/feature/auth
```
**Salida Esperada:**
```text
4f1a92e34c9c1b72e5d91aa8931b6210419a4891
```

3. Realizá un commit en `feature/auth` para simular nueva funcionalidad:
```bash
echo 'func Auth() { println("JWT Auth") }' >> auth.go
git add auth.go
git commit -m "Feat(auth): Add JWT validation logic"
```

4. Volvé al branch `main` y creá una edición en conflicto sobre `main.go`:
```bash
git checkout main
echo '// Main entrypoint updated on main branch' >> main.go
git add main.go
git commit -m "Refactor(main): Update main package inline docs"
```

5. Visualizá los branches divergentes en el DAG usando el formato de gráfico de log:
```bash
git log --graph --oneline --all
```
**Salida Esperada:**
```text
* a1b2c3d (HEAD -> main) Refactor(main): Update main package inline docs
| * 7e8f9a0 (feature/auth) Feat(auth): Add JWT validation logic
|/
* 4f1a92e Feat: Add core app entrypoint and ignore rules
* 8f420a8 Initial production config commit
```

6. Ejecutá un 3-Way Merge desde `feature/auth` hacia `main`:
```bash
git merge feature/auth -m "Merge branch 'feature/auth' into main"
```
**Salida Esperada:**
```text
Merge made by the 'ort' strategy.
 auth.go | 1 +
 1 file changed, 1 insertion(+)
 create mode 100644 auth.go
```

7. Inspeccioná la estructura del objeto Merge Commit recién creado:
```bash
git cat-file -p HEAD
```
**Salida Esperada:**
```text
tree 6f2a89012cd345ef1a2b3c4d5e6f7a8b9c0d1e2f
parent a1b2c3d4e5f67890123456789abcdef012345678
parent 7e8f9a0123456789abcdef0123456789abcdef01
author SRE Lead <sre@example.com> 1754518500 -0400
committer SRE Lead <sre@example.com> 1754518500 -0400

Merge branch 'feature/auth' into main
```

8. Creá un **Annotated Release Tag** con detalles criptográficos de la firma del tagger:
```bash
git tag -a v1.0.0 -m "Production Release Candidate v1.0.0"
git cat-file -p v1.0.0
```
**Salida Esperada:**
```text
object e4b2c19876543210fedcba9876543210fedcba98
type commit
tag v1.0.0
tagger SRE Lead <sre@example.com> 1754518550 -0400

Production Release Candidate v1.0.0
```

9. Configurá los remotos upstream y origin para simular un flujo de trabajo Enterprise Fork / Pull Request:
```bash
git remote add origin git@github.com:my-org-fork/scm-internals-lab.git
git remote add upstream git@github.com:canonical-enterprise/scm-internals-lab.git
git remote -v
```
**Salida Esperada:**
```text
origin	git@github.com:my-org-fork/scm-internals-lab.git (fetch)
origin	git@github.com:my-org-fork/scm-internals-lab.git (push)
upstream	git@github.com:canonical-enterprise/scm-internals-lab.git (fetch)
upstream	git@github.com:canonical-enterprise/scm-internals-lab.git (push)
```

---

### Preguntas de Verificación (Lab Block 3)

**Pregunta 3.1:** ¿Qué distingue a un **Annotated Tag** (`git tag -a`) de un **Lightweight Tag** (`git tag <name>`) dentro de la arquitectura del Git Object Storage?
- A) Un lightweight tag crea un archivo tarball comprimido en `.git/objects/pack/`.
- B) Un annotated tag crea un objeto Git completo en la base de datos que almacena la identidad del tagger, fecha y mensaje, mientras que un lightweight tag es puramente un archivo de puntero de referencia almacenado en `.git/refs/tags/`.
- C) Los lightweight tags requieren claves de firma GPG, mientras que los annotated tags no.
- D) Los annotated tags solo pueden apuntar a objetos Blob, mientras que los lightweight tags apuntan a Commits.

**Pregunta 3.2:** En un flujo de trabajo open-source basado en forks, ¿cuál es el propósito estándar de configurar un remoto `upstream` junto con `origin`?
- A) `upstream` apunta a tu fork personal en GitHub, mientras que `origin` apunta al sistema de archivos local.
- B) `upstream` apunta al repositorio del proyecto central canónico para obtener (fetch) cambios, mientras que `origin` apunta a tu fork personal con permisos de escritura para hacer push de los branches de características.
- C) `upstream` realiza merge automáticamente de las pull requests entrantes sin verificación local.
- D) `origin` almacena código que no es de producción, mientras que `upstream` almacena binarios compilados.

---

## Lab Block 4: Diagnóstico de Producción, Auditoría de Historial y Técnicas de Recuperación

Los SRE e Ingenieros de Plataforma deben diagnosticar estados corruptos, recuperar commits colgantes (dangling commits) perdidos debido a resets forzados e inspeccionar el historial DAG de commits utilizando opciones granulares de la CLI de diagnóstico.

### Pasos Guiados Prácticos

1. Simulá un reset destructivo accidental de un branch perdiendo el último merge commit:
```bash
cd ~/scm-internals-lab
PREV_COMMIT=$(git rev-parse HEAD~1)
git reset --hard ${PREV_COMMIT}
git log --oneline -n 2
```
**Salida Esperada:**
```text
HEAD is now at a1b2c3d Refactor(main): Update main package inline docs
a1b2c3d Refactor(main): Update main package inline docs
4f1a92e Feat: Add core app entrypoint and ignore rules
```

2. Inspeccioná el **Git Reflog** para ubicar el commit colgante (dangling commit) perdido durante el reset hard:
```bash
git reflog
```
**Salida Esperada:**
```text
a1b2c3d (HEAD -> main) HEAD@{0}: reset: moving to HEAD~1
e4b2c19 (v1.0.0) HEAD@{1}: merge feature/auth: Merge made by the 'ort' strategy.
a1b2c3d (HEAD -> main) HEAD@{2}: commit: Refactor(main): Update main package inline docs
```

3. Recuperá el merge commit colgante desde el puntero de reflog:
```bash
git reset --hard HEAD@{1}
git log --oneline -n 3
```
**Salida Esperada:**
```text
HEAD is now at e4b2c19 Merge branch 'feature/auth' into main
e4b2c19 (HEAD -> main, tag: v1.0.0) Merge branch 'feature/auth' into main
a1b2c3d Refactor(main): Update main package inline docs
7e8f9a0 (feature/auth) Feat(auth): Add JWT validation logic
```

4. Auditá la integridad de los objetos del repositorio y buscá objetos colgantes inalcanzables usando `git fsck`:
```bash
git fsck --full --strict
```
**Salida Esperada:**
```text
Notice: Checking object directory
Notice: Checking finished craft, 0 dangling objects found.
```

5. Realizá una optimización de empaquetado de objetos de bajo nivel y garbage collection:
```bash
git gc --prune=now
ls -la .git/objects/pack/
```
**Salida Esperada:**
```text
total 16
drwxr-rf- 2 user user 4096 Aug  6 19:35 .
drwxr-rf- 5 user user 4096 Aug  6 19:35 ..
-r--r--r-- 1 user user 2048 Aug  6 19:35 pack-a1b2c3d4e5f67890123456789abcdef012345678.idx
-r--r--r-- 1 user user 4096 Aug  6 19:35 pack-a1b2c3d4e5f67890123456789abcdef012345678.pack
```

---

### Preguntas de Verificación (Lab Block 4)

**Pregunta 4.1:** Un desarrollador ejecuta `git branch -D hotfix-sec` eliminando un branch de característica antes de hacer push al remoto. ¿Qué comando de diagnóstico le permite al ingeniero de plataforma ubicar el hash SHA del extremo (tip) del branch eliminado para su recuperación?
- A) `git status --all`
- B) `git reflog`
- C) `git remote show origin`
- D) `git check-ignore`

**Pregunta 4.2:** ¿Cuál es la función principal de `git gc` (Garbage Collection) dentro de un repositorio de Git en producción?
- A) Elimina archivos no rastreados (untracked) en el directorio de trabajo que tengan más de 24 horas de antigüedad.
- B) Comprime objetos sueltos (loose objects) individuales en archivos de índice binarios `.pack` consolidados y elimina objetos huérfanos inalcanzables.
- C) Realiza merge automáticamente de los branches de características obsoletos hacia `main`.
- D) Sincroniza commits locales con el repositorio remoto `upstream`.

---

<details>
<summary>Clave de Respuestas de los Ejercicios y Explicaciones de Arquitectura Profundas</summary>

### Respuestas del Lab Block 1

**Pregunta 1.1: B**
- **Explicación Profunda:** El almacén de objetos (object store) de Git es direccionable por contenido. El hash SHA del objeto se calcula exclusivamente a través del resumen criptográfico de `SHA-1("blob " + content_length + "\0" + payload_bytes)`. Debido a que tanto `app-dev.env` como `app-prod.env` contienen cargas útiles de bytes idénticas (`DB_PORT=5432`), producen exactamente el mismo hash SHA. Git almacena solo **un** objeto blob dentro de `.git/objects/`. Las distintas rutas de archivos (`app-dev.env` vs `app-prod.env`) se registran por separado en el objeto **Tree** que apunta a ese único SHA de blob compartido.

**Pregunta 1.2: C**
- **Explicación Profunda:** El archivo `.git/HEAD` define el contexto activo del directorio de trabajo del repositorio. En un estado normal, contiene una cadena de referencia simbólica (ej., `ref: refs/heads/main`). Cuando cambias de branch mediante `git checkout` o `git switch`, Git actualiza `.git/HEAD` para que apunte al archivo de referencia del branch destino dentro de `.git/refs/heads/`.

---

### Respuestas del Lab Block 2

**Pregunta 2.1: B**
- **Explicación Profunda:** `git diff` sin flags compara el **Working Directory** contra el **Staging Area (Index)**. Agregar la flag `--staged` (o `--cached`) le indica a Git que calcule el diff entre el **Staging Area (Index)** y el **commit HEAD** actual en el repositorio. Esto permite a los ingenieros revisar exactamente qué se escribirá en disco antes de ejecutar `git commit`.

**Pregunta 2.2: C**
- **Explicación Profunda:** Al ejecutar `git add .`, Git evalúa todos los archivos no rastreados y modificados contra las reglas de coincidencia definidas en los archivos `.gitignore`. Los archivos que coinciden con expresiones ignoradas (como `*.key`) se omiten de forma segura sin generar errores. Si un ingeniero desea explícitamente forzar el staging de un archivo ignorado, debe omitir la verificación utilizando `git add -f <filename>`.

---

### Respuestas del Lab Block 3

**Pregunta 3.1: B**
- **Explicación Profunda:** Un **Lightweight Tag** no es más que un archivo de referencia de texto dentro de `.git/refs/tags/<tag_name>` que contiene una cadena de hash de commit de 40 caracteres (similar a un puntero de branch que no se mueve). Un **Annotated Tag** (`git tag -a`) crea un **Tag Object** inmutable real en `.git/objects/`. Este objeto contiene su propio hash SHA, el SHA del commit destino, metadatos de identidad del tagger, cadena de marca de tiempo, mensaje de log explícito y un bloque de firma GPG opcional.

**Pregunta 3.2: B**
- **Explicación Profunda:** En los flujos de trabajo enterprise estándar basados en forks open-source (ej., al contribuir a repositorios de Kubernetes o CNCF), las cuentas de los desarrolladores no poseen derechos directos de push al repositorio canónico. Los desarrolladores hacen un fork del proyecto bajo su propia cuenta (`origin`) y registran el repositorio canónico original como `upstream`. El remoto `upstream` se obtiene (fetch) localmente para mantener los branches principales sincronizados, mientras que los branches de características se envían (push) a `origin` para abrir Pull Requests/Merge Requests de vuelta hacia `upstream`.

---

### Respuestas del Lab Block 4

**Pregunta 4.1: B**
- **Explicación Profunda:** Git mantiene un diario transaccional local llamado **Reflog** (`.git/logs/HEAD` y `.git/logs/refs/heads/<branch>`). El reflog registra cada movimiento de `HEAD` y referencias de branches resultantes de commits, resets, checkouts, merges o acciones de rebase. Incluso si una referencia de branch local se elimina mediante `git branch -D`, los commits históricos permanecen dentro de `.git/objects/` hasta que se ejecute el garbage collection, y su hash SHA exacto se puede recuperar desde `git reflog`.

**Pregunta 4.2: B**
- **Explicación Profunda:** Con el tiempo, las operaciones generan archivos de objetos sueltos (loose objects) bajo `.git/objects/XX/`. `git gc` (Garbage Collection) optimiza el rendimiento del almacenamiento del repositorio comprimiendo múltiples objetos blob, tree y commit sueltos en **Packfiles** (`.pack`) unificados con compresión por delta, junto con mapeos de índices (`.idx`). Además, elimina los objetos colgantes inalcanzables que superen el umbral `gc.pruneExpire` (por defecto 2 semanas).

</details>