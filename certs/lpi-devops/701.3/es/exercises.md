# LPI DevOps Tools Engineer (Examen 701-100) — Tema 1.3: Source Code Management
**Peso:** 8.33  
**Audiencia Objetivo:** SREs, Platform Engineers y DevOps Engineers  
**Referencia Oficial:** [LPI DevOps Tools Engineer Overview](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/) | [Git Documentation](https://git-scm.com/doc)

---

## 1. Profundización Arquitectónica y Teórica

### 1.1 Arquitectura de Control de Versiones Centralizado vs. Distribuido

| Atributo | SCM Centralizado (ej., Subversion / SVN) | SCM Distribuido (ej., Git) |
| :--- | :--- | :--- |
| **Almacenamiento de Datos** | Un único servidor de base de datos central contiene el historial completo. Los clientes almacenan copias de trabajo (working copies) de revisiones específicas. | Cada clon es un repositorio completo que contiene el historial completo, la tienda de objetos (object store) y el grafo de referencias (ref graph). |
| **Dependencia de Red** | Los commits, diffs, blame y logs de historial requieren conectividad de red al servidor central. | Todas las operaciones principales (`commit`, `log`, `diff`, `branch`, `rebase`) se ejecutan localmente fuera de línea (offline). La red solo se requiere para `fetch`/`push`. |
| **Mecánica de Ramificación (Branching)** | Operaciones de copia dentro del árbol remoto (ej., `svn copy trunk/ branches/feature`). Almacenamiento O(N) o seguimiento de metadatos de directorios del servidor. | Actualizaciones ligeras de referencias (un archivo de texto de 41 bytes que contiene un hash SHA-1/SHA-256 de 40 caracteres que apunta a un objeto commit). Complejidad temporal O(1). |
| **Concurrencia e Integridad** | Lock-Modify-Unlock o Copy-Modify-Merge; los números de revisión son enteros monotónicos (ej., r1042). | Grafo Acíclico Dirigido (DAG) de objetos direccionables por contenido hasheados con SHA-1/SHA-256 (arquitectura de Árbol de Merkle). Criptográficamente inmutable. |
| **Dominio de Falla** | La corrupción de datos o el tiempo de inactividad (downtime) del servidor central detiene todas las operaciones de commit/historial en toda la organización. | Totalmente descentralizado; la máquina de cada ingeniero actúa como un respaldo (backup) completo del estado del repositorio. |

---

### 1.2 Motor de Almacenamiento de Objetos de Git y Estructura de Directorios

Git funciona como un sistema de archivos direccionable por contenido construido sobre un Grafo Acíclico Dirigido (DAG). El directorio `.git` contiene el estado completo:

```
.git/
├── HEAD               # Symbolically points to the active branch ref (e.g., ref: refs/heads/main)
├── config             # Repository-specific configuration file
├── description        # Used by GitWeb (default description file)
├── hooks/             # Client-side and server-side lifecycle hook scripts
├── index              # Binary staging area (Cache) mapping working tree to object database
├── info/
│   └── exclude        # Local ignore pattern file (unshared gitignore)
├── objects/           # Object database (Content-addressable store)
│   ├── [0-9a-f][0-9a-f]/ # Loose objects partitioned by first 2 hex digits of SHA
│   ├── info/          # Object pack metadata
│   └── pack/          # Packed objects (.pack) and index files (.idx) for Delta Compression
└── refs/              # References pointers
    ├── heads/         # Local branch pointers
    ├── tags/          # Tag pointers (lightweight and annotated)
    └── remotes/       # Remote-tracking branch pointers
```

#### Los Cuatro Tipos Principales de Objetos

1. **Blob (`blob`)**: Almacena el payload binario del archivo sin procesar (raw). No almacena nombres de archivos, marcas de tiempo de modificación, estructuras de directorios ni permisos (excepto el bit ejecutable).
2. **Tree (`tree`)**: Representa un directorio. Almacena listados de directorios mapeando hashes SHA de blobs a nombres de archivos, modos de archivos (`100644` archivo estándar, `100755` ejecutable, `120000` symlink, `040000` subdirectorio) y SHAs de trees hijos.
3. **Commit (`commit`)**: Apunta a un objeto `tree` de nivel superior que representa el snapshot de la raíz del proyecto en ese momento. Contiene metadatos: SHA(s) del commit padre, autor (nombre, correo electrónico, marca de tiempo epoch, desfase de zona horaria), committer, bloque de firma GPG (si está firmado) y el mensaje de commit.
4. **Annotated Tag (`tag`)**: Un objeto explícito que apunta a un commit específico (o a cualquier tipo de objeto). Contiene la identidad del tagger, marca de tiempo, mensaje personalizado del tag y firma GPG opcional.

---

## 2. Ejercicios Guiados de Producción

---

### Ejercicio 1: Inspección de Bajo Nivel de la Tienda de Objetos de Git y Construcción Manual de Objetos Plumbing

En este ejercicio, omitirás los comandos de alto nivel "porcelain" (`git add`, `git commit`) y utilizarás comandos de bajo nivel "plumbing" para construir manualmente blobs, trees y objetos commit directamente dentro de `.git/objects`.

#### Paso 1: Inicializar un repositorio vacío e inspeccionar el estado del directorio

```bash
mkdir -p /tmp/git-internals-lab && cd /tmp/git-internals-lab
git init
ls -la .git/
```

*Salida Esperada:*
```text
Initialized empty Git repository in /tmp/git-internals-lab/.git/
total 24
drwxr-xr-x 7 student student 4096 Aug 07 04:45 .
drwxr-xr-x 3 student student 4096 Aug 07 04:45 ..
-rw-r--r-- 1 student student   23 Aug 07 04:45 HEAD
-rw-r--r-- 1 student student  130 Aug 07 04:45 config
-rw-r--r-- 1 student student   73 Aug 07 04:45 description
drwxr-xr-x 2 student student 4096 Aug 07 04:45 hooks
drwxr-xr-x 2 student student 4096 Aug 07 04:45 info
drwxr-xr-x 4 student student 4096 Aug 07 04:45 objects
drwxr-xr-x 4 student student 4096 Aug 07 04:45 refs
```

#### Paso 2: Escribir manualmente un Blob en la Base de Datos de Objetos sin crear un archivo en el working tree

```bash
BLOB_SHA=$(echo "DB_HOST=10.0.4.15" | git hash-object -w --stdin)
echo "Generated Blob SHA: ${BLOB_SHA}"
git cat-file -t ${BLOB_SHA}
git cat-file -p ${BLOB_SHA}
find .git/objects -type f
```

*Salida Esperada:*
```text
Generated Blob SHA: f4e84b8d7010f3c5b5258e727e466bd6e1d7cf9d
blob
DB_HOST=10.0.4.15
.git/objects/f4/e84b8d7010f3c5b5258e727e466bd6e1d7cf9d
```

#### Paso 3: Colocar el Blob en el Staging Area (Index) y escribir un objeto Tree

```bash
git update-index --add --cacheinfo 100644 ${BLOB_SHA} config/db.env
TREE_SHA=$(git write-tree)
echo "Generated Tree SHA: ${TREE_SHA}"
git cat-file -p ${TREE_SHA}
```

*Salida Esperada:*
```text
Generated Tree SHA: a942e61266e74b5c777aa0d6c072c49980d903cd
040000 tree 82cb7f5a6b0c20f1b2b8e3a2b7f32906e5d81a94	config
```

```bash
git cat-file -p 82cb7f5a6b0c20f1b2b8e3a2b7f32906e5d81a94
```

*Salida Esperada:*
```text
100644 blob f4e84b8d7010f3c5b5258e727e466bd6e1d7cf9d	db.env
```

#### Paso 4: Crear manualmente un objeto Commit que apunte al Tree y actualizar `refs/heads/main`

```bash
COMMIT_SHA=$(echo "feat(config): initialize database connection parameters" | git commit-tree ${TREE_SHA})
echo "Generated Commit SHA: ${COMMIT_SHA}"
git cat-file -p ${COMMIT_SHA}
git update-ref refs/heads/main ${COMMIT_SHA}
git symbolic-ref HEAD refs/heads/main
git log -1
```

*Salida Esperada:*
```text
Generated Commit SHA: d29f8c14a90a43e7b1a20822649a37e114bc5d09
tree a942e61266e74b5c777aa0d6c072c49980d903cd
author SRE Engineer <sre@company.internal> 1754541929 -0400
committer SRE Engineer <sre@company.internal> 1754541929 -0400

feat(config): initialize database connection parameters

commit d29f8c14a90a43e7b1a20822649a37e114bc5d09 (HEAD -> main)
Author: SRE Engineer <sre@company.internal>
Date:   Thu Aug 7 04:45:29 2026 -0400

    feat(config): initialize database connection parameters
```

---

#### Preguntas de Comprensión del Ejercicio 1

1. **Pregunta 1.1:** ¿Por qué la creación de dos archivos idénticos con exactamente el mismo contenido en diferentes subdirectorios da como resultado la creación de solo **un** objeto blob en `.git/objects`?
2. **Pregunta 1.2:** ¿Qué comando plumbing ejecutarías para verificar si un objeto de Git almacenado en `.git/objects/a9/42e612...` está dañado sin despaquetar su contenido manualmente?

---

### Ejercicio 2: Reescritura Avanzada del Historial, Rebase Interactivo y Recuperación mediante Reflog

En equipos de ingeniería de alto rendimiento, un historial de commits limpio es obligatorio antes de fusionar PRs. Realizarás un rebase interactivo para hacer squash de múltiples commits, modificarás un mensaje de commit y luego te recuperarás de una falla de rebase destructiva utilizando `git reflog`.

#### Paso 1: Poblar el repositorio con commits sintéticos

```bash
cd /tmp/git-internals-lab
echo "v1.0" > app.py && git add app.py && git commit -m "feat: base application v1"
echo "v1.1" >> app.py && git commit -am "fix: typo in print statement"
echo "v1.2" >> app.py && git commit -am "WIP: temporary debug logs"
echo "v1.3" >> app.py && git commit -am "feat: added login feature"
git log --oneline
```

*Salida Esperada:*
```text
e9a2f1c (HEAD -> main) feat: added login feature
7b41d0e WIP: temporary debug logs
3c82a9f fix: typo in print statement
a1f802d feat: base application v1
d29f8c1 feat(config): initialize database connection parameters
```

#### Paso 2: Realizar un rebase automatizado no interactivo para hacer squash de los últimos 3 commits en uno solo

Simulamos hacer squash de los 3 commits superiores (`e9a2f1c`, `7b41d0e`, `3c82a9f`) sobre `a1f802d`.

```bash
GIT_SEQUENCE_EDITOR="sed -i '2,3 s/^pick/squash/'" git rebase -i HEAD~3
git log --oneline
```

*Salida Esperada:*
```text
[detached HEAD 9f3e1a0] fix: typo in print statement
 Date: Thu Aug 7 04:46:12 2026 -0400
 1 file changed, 3 insertions(+)
Successfully rebased and updated refs/heads/main.

9f3e1a0 (HEAD -> main) fix: typo in print statement
a1f802d feat: base application v1
d29f8c1 feat(config): initialize database connection parameters
```

#### Paso 3: Simular una operación destructiva de git reset hard

```bash
git reset --hard d29f8c1
git log --oneline
```

*Salida Esperada:*
```text
HEAD is now at d29f8c1 feat(config): initialize database connection parameters

d29f8c1 (HEAD -> main) feat(config): initialize database connection parameters
```

#### Paso 4: Recuperar commits perdidos usando `git reflog` y `git reset`

```bash
git reflog -n 5
```

*Salida Esperada:*
```text
d29f8c1 (HEAD -> main) HEAD@{0}: reset: moving to d29f8c1
9f3e1a0 HEAD@{1}: rebase (finish): returning to refs/heads/main
9f3e1a0 HEAD@{2}: rebase (squash): fix: typo in print statement
a1f802d HEAD@{3}: rebase (start): checkout HEAD~3
e9a2f1c HEAD@{4}: commit: feat: added login feature
```

```bash
git reset --hard HEAD@{1}
git log --oneline
```

*Salida Esperada:*
```text
HEAD is now at 9f3e1a0 fix: typo in print statement

9f3e1a0 (HEAD -> main) fix: typo in print statement
a1f802d feat: base application v1
d29f8c1 feat(config): initialize database connection parameters
```

---

#### Preguntas de Comprensión del Ejercicio 2

1. **Pregunta 2.1:** ¿Cuál es la diferencia fundamental entre `git reset --soft`, `git reset --mixed` y `git reset --hard` con respecto al working directory, el index y el historial de commits?
2. **Pregunta 2.2:** Si un desarrollador ejecuta `git gc` (Garbage Collection) o `git prune` inmediatamente después de un `git reset --hard` destructivo, ¿puede `git reflog` garantizar aún la recuperación de los commits colgantes (dangling commits) inalcanzables? Explica por qué sí o por qué no.

---

### Ejercicio 3: Búsqueda Automatizada de Errores usando `git bisect` con Scripts de Verificación Personalizados

Cuando las regresiones llegan a producción a lo largo de cientos de commits, la búsqueda binaria a través de `git bisect` combinada con scripts ejecutables aísla automáticamente los commits defectuosos.

#### Paso 1: Generar un repositorio de suite de pruebas con una regresión oculta

```bash
mkdir -p /tmp/git-bisect-lab && cd /tmp/git-bisect-lab
git init

# Commit 1 (Good state)
echo "def calculate(a, b): return a + b" > math_lib.py
echo "assert calculate(2, 3) == 5" > test_app.py
git add . && git commit -m "commit 1: initial math lib"

# Commits 2 to 6 (Normal changes)
for i in {2..6}; do
    echo "# Change iteration $i" >> math_lib.py
    git commit -am "commit $i: update documentation"
done

# Commit 7 (Introduce subtle bug)
echo "def calculate(a, b): return a - b" > math_lib.py
git commit -am "commit 7: refactor core calculation logic"

# Commits 8 to 12 (More commits following the bug)
for i in {8..12}; do
    echo "# Post bug change $i" >> math_lib.py
    git commit -am "commit $i: feature enhancement $i"
done
```

#### Paso 2: Crear un script de prueba de aserción automatizado

```bash
cat << 'EOF' > /tmp/git-bisect-lab/verify.sh
#!/bin/bash
python3 -c "import math_lib; assert math_lib.calculate(2, 3) == 5" > /dev/null 2>&1
exit $?
EOF
chmod +x /tmp/git-bisect-lab/verify.sh
```

#### Paso 3: Ejecutar `git bisect run` no interactivo

```bash
GOOD_COMMIT=$(git rev-parse HEAD~11)
BAD_COMMIT=$(git rev-parse HEAD)

git bisect start ${BAD_COMMIT} ${GOOD_COMMIT}
git bisect run /tmp/git-bisect-lab/verify.sh
```

*Salida Esperada:*
```text
Bisecting: 5 revisions left to test after this (roughly 3 steps)
[a2d8f9e1...] commit 6: update documentation
running /tmp/git-bisect-lab/verify.sh
Bisecting: 2 revisions left to test after this (roughly 2 steps)
[c7f1b2d4...] commit 8: feature enhancement 8
running /tmp/git-bisect-lab/verify.sh
Bisecting: 0 revisions left to test after this (roughly 1 step)
[e4a9c1b2...] commit 7: refactor core calculation logic
running /tmp/git-bisect-lab/verify.sh
e4a9c1b2f8a1c9e3b5d2a4f6e8c0a2b4c6d8e0f1 is the first bad commit
commit e4a9c1b2f8a1c9e3b5d2a4f6e8c0a2b4c6d8e0f1
Author: SRE Engineer <sre@company.internal>
Date:   Thu Aug 7 04:47:15 2026 -0400

    commit 7: refactor core calculation logic

 math_lib.py | 2 +-
 1 file changed, 1 insertion(+), 1 deletion(-)
bisect run success
```

#### Paso 4: Restablecer el estado de bisect al HEAD normal de la rama

```bash
git bisect reset
```

*Salida Esperada:*
```text
Previous HEAD position was e4a9c1b commit 7: refactor core calculation logic
Switched to branch 'main'
```

---

#### Preguntas de Comprensión del Ejercicio 3

1. **Pregunta 3.1:** ¿Qué códigos de salida (exit codes) debe pasar el script de prueba a `git bisect run` para distinguir entre un **good commit**, un **bad commit** y un **untestable commit** (ej., el código no se compila debido a un error de sintaxis de dependencia independiente)?
2. **Pregunta 3.2:** ¿Cómo maneja `git bisect` los commits de fusión (merge commits) durante una sesión de bisect de forma predeterminada, y qué riesgo ocurre si las ramas de características (feature branches) se fusionaron sin un historial lineal?

---

### Ejercicio 4: Control de Acceso Empresarial e Implementación de Hook Pre-Receive del Lado del Servidor

Los hooks del lado del servidor se ejecutan en el servidor Git remoto (repositorio bare) para hacer cumplir la política corporativa antes de que se actualicen las referencias. En este ejercicio, crearás un hook `pre-receive` personalizado que bloquea commits no firmados o commits que contengan credenciales/secretos ilegales.

#### Paso 1: Configurar un repositorio de servidor central bare y un clon local

```bash
mkdir -p /tmp/remote-repo.git && cd /tmp/remote-repo.git
git init --bare

cd /tmp
git clone /tmp/remote-repo.git /tmp/local-developer
cd /tmp/local-developer
git config user.name "Developer One"
git config user.email "developer@company.internal"
```

#### Paso 2: Implementar un hook `pre-receive` del lado del servidor en el repositorio bare

El hook verifica el payload de cada commit entrante para evitar que llaves privadas hardcodeadas (ej., `-----BEGIN RSA PRIVATE KEY-----`) o llaves de AWS (`AKIA...`) lleguen al DAG del servidor.

```bash
cat << 'EOF' > /tmp/remote-repo.git/hooks/pre-receive
#!/usr/bin/env bash
set -e

# pre-receive reads standard input: <old-value> <new-value> <ref-name>
while read -r oldrev newrev refname; do
    # Zero SHA means branch deletion
    if [ "$newrev" = "0000000000000000000000000000000000000000" ]; then
        continue
    fi

    # Determine revision range for new commits
    if [ "$oldrev" = "0000000000000000000000000000000000000000" ]; then
        REV_RANGE="$newrev"
    else
        REV_RANGE="$oldrev..$newrev"
    fi

    # Scan committed objects for secret patterns
    for commit in $(git rev-list "$REV_RANGE"); do
        # Inspect blob changes in the commit
        if git diff-tree --no-commit-id --name-only -r "$commit" | grep -q ""; then
            if git grep -E "(AKIA[0-9A-Z]{16}|-----BEGIN (RSA|OPENSSH) PRIVATE KEY-----)" "$commit"; then
                echo "--------------------------------------------------------" >&2
                echo "[POLICY ERROR] Security policy violation detected!" >&2
                echo "Commit $commit contains hardcoded secrets/private keys." >&2
                echo "Push rejected by server pre-receive hook." >&2
                echo "--------------------------------------------------------" >&2
                exit 1
            fi
        fi
    done
done
exit 0
EOF

chmod +x /tmp/remote-repo.git/hooks/pre-receive
```

#### Paso 3: Probar el push de un commit en conformidad desde la máquina local del desarrollador

```bash
cd /tmp/local-developer
echo "hello world" > README.md
git add README.md
git commit -m "docs: add readme file"
git push origin HEAD:refs/heads/main
```

*Salida Esperada:*
```text
Enumerating objects: 3, done.
Counting objects: 100% (3/3), done.
Writing objects: 100% (3/3), 242 bytes | 242.00 KiB/s, done.
Total 3 (delta 0), reused 0 (delta 0), pack-reused 0
To /tmp/remote-repo.git
 * [new branch]      HEAD -> main
```

#### Paso 4: Probar el push de un commit que no cumple las políticas al contener una llave secreta de AWS hardcodeada

```bash
cd /tmp/local-developer
echo "AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE" > aws_config.txt
git add aws_config.txt
git commit -m "feat: add aws credentials config"
git push origin HEAD:refs/heads/main
```

*Salida Esperada:*
```text
Enumerating objects: 4, done.
Counting objects: 100% (4/4), done.
Delta compression using up to 8 threads
Compressing objects: 100% (2/2), done.
Writing objects: 100% (3/3), 340 bytes | 340.00 KiB/s, done.
Total 3 (delta 0), reused 0 (delta 0), pack-reused 0
remote: --------------------------------------------------------
remote: [POLICY ERROR] Security policy violation detected!
remote: Commit c8f2b1d3a4e9f5c... contains hardcoded secrets/private keys.
remote: Push rejected by server pre-receive hook.
remote: --------------------------------------------------------
error: failed to push some refs to '/tmp/remote-repo.git'
```

---

#### Preguntas de Comprensión del Ejercicio 4

1. **Pregunta 4.1:** Contrasta los hooks `pre-commit` (del lado del cliente) con los hooks `pre-receive` (del lado del servidor) en términos de integridad del cumplimiento de políticas y capacidades de omisión (`--no-verify`).
2. **Pregunta 4.2:** ¿Cuál es el orden de ejecución de los hooks del lado del servidor en un remoto de Git durante una operación de push (`pre-receive`, `update`, `post-receive`) y cuáles de estos pueden rechazar una transacción?

---

### Ejercicio 5: Gestión del Grafo de Dependencias a Escala con `git worktree` y `git submodule`

Los monorepositorios y las plataformas multirrepositorio modernas utilizan submódulos de Git para módulos externos y `git worktree` para aislar el cambio de contexto concurrente de funciones (features) sin clonar ni realizar operaciones de stash.

#### Paso 1: Gestionar hotfixes simultáneos sin cambiar de rama utilizando `git worktree`

```bash
cd /tmp/local-developer
git worktree list
```

*Salida Esperada:*
```text
/tmp/local-developer  c8f2b1d [main]
```

```bash
git worktree add -b hotfix/db-connection /tmp/hotfix-workspace main
cd /tmp/hotfix-workspace
git status
```

*Salida Esperada:*
```text
Preparing worktree (new branch 'hotfix/db-connection')
HEAD is now at c8f2b1d docs: add readme file
On branch hotfix/db-connection
nothing to commit, working tree clean
```

#### Paso 2: Limpiar el directorio worktree

```bash
cd /tmp/local-developer
git worktree remove /tmp/hotfix-workspace
git branch -D hotfix/db-connection
```

*Salida Esperada:*
```text
Deleted branch hotfix/db-connection (was c8f2b1d).
```

#### Paso 3: Incrustar un módulo compartido externo utilizando `git submodule`

```bash
# Setup dependency repository
mkdir -p /tmp/shared-lib.git && cd /tmp/shared-lib.git
git init --bare

cd /tmp
git clone /tmp/shared-lib.git /tmp/shared-lib-dev
cd /tmp/shared-lib-dev
echo "def logger(msg): print(msg)" > logger.py
git add logger.py && git commit -m "feat: initial logger lib"
git push origin HEAD:refs/heads/main

# Add submodule to main project
cd /tmp/local-developer
git submodule add /tmp/shared-lib.git libs/shared-logger
cat .gitmodules
```

*Salida Esperada:*
```text
Cloning into '/tmp/local-developer/libs/shared-logger'...
done.
[submodule "libs/shared-logger"]
	path = libs/shared-logger
	url = /tmp/shared-lib.git
```

#### Paso 4: Verificar la representación del puntero del submódulo dentro del index del repositorio anfitrión

```bash
git ls-files --stage libs/shared-logger
```

*Salida Esperada:*
```text
160000 7f4a2b1c8e9d3f5a2b1c4e7d9f2a4b6c8e0f1a3b 0	libs/shared-logger
```

---

#### Preguntas de Comprensión del Ejercicio 5

1. **Pregunta 5.1:** ¿Qué representa el modo de archivo `160000` en los objetos tree de Git y por qué un repositorio anfitrión almacena un hash de commit en lugar de blobs de archivos para las rutas de los submódulos?
2. **Pregunta 5.2:** Cuando un usuario nuevo clona un repositorio que contiene submódulos mediante el comando estándar `git clone <url>`, ¿por qué los directorios de los submódulos están vacíos y qué comandos exactos de la CLI los pueblan?

---

## 3. Clave de Respuestas y Explicaciones Detalladas

<details>
<summary><strong>Haz clic para expandir las Respuestas y Explicaciones Detalladas</strong></summary>

### Respuestas al Ejercicio 1

* **1.1 Respuesta:**  
  Git es un **sistema de archivos direccionable por contenido**. El hash SHA-1/SHA-256 de un objeto blob se calcula estrictamente a partir de la longitud de su payload y sus contenidos en bytes (`SHA("blob " + size + "\0" + content)`). Los nombres de archivos, las rutas relativas de directorios y los permisos de archivos **no** se almacenan dentro del propio blob; se almacenan en el objeto **Tree** padre. Por lo tanto, archivos idénticos en diferentes directorios generan hashes idénticos y se resuelven en exactamente el mismo blob único en `.git/objects`. Esto proporciona una desduplicación implícita.

* **1.2 Respuesta:**  
  Utiliza el comando plumbing `git fsck --strict` o `git cat-file -e <SHA>`. `git fsck` (FileSystem Check) verifica la integridad de la suma de comprobación (checksum) SHA-1 de todos los objetos en la base de datos contra su payload comprimido y comprueba la validez de los punteros del DAG.

---

### Respuestas al Ejercicio 2

* **2.1 Respuesta:**  
  * `git reset --soft <commit>`: Mueve el puntero HEAD a `<commit>`. Deja el **Index (Staging Area)** y el **Working Directory** intactos. Los cambios entre el HEAD original y el commit objetivo permanecen en el staging area.
  * `git reset --mixed <commit>` (predeterminado): Mueve el puntero HEAD a `<commit>` Y actualiza el **Index** para que coincida con `<commit>`. Deja el **Working Directory** intacto. Los cambios aparecen como modificaciones no preparadas (unstaged).
  * `git reset --hard <commit>`: Mueve el puntero HEAD a `<commit>`, actualiza el **Index** Y restablece el **Working Directory** para que coincida con `<commit>`. Todos los cambios locales sin commit y los archivos preparados no rastreados se sobrescriben permanentemente.

* **2.2 Respuesta:**  
  **No**, pero con una condición de límite de tiempo. Ejecutar `git reset --hard` elimina los punteros de referencia de las ramas, dejando los commits inalcanzables desde cualquier punta de rama o etiqueta (dangling commits). Sin embargo, `git reflog` mantiene entradas de referencia que apuntan a esos SHAs de commit durante una ventana de retención configurable (`gc.reflogExpire`, por defecto **90 días** para referencias alcanzables, **30 días** para referencias inalcanzables).  
  `git gc` **no** purgará los commits colgantes mientras estén referenciados por alguna entrada en `.git/logs/HEAD` o `.git/logs/refs/`. Solo si se ejecuta explícitamente `git reflog expire --expire=now --all` antes de `git gc --prune=now`, `git gc` eliminará los objetos inalcanzables del disco.

---

### Respuestas al Ejercicio 3

* **3.1 Respuesta:**  
  * **Código de salida `0`**: Señala a `git bisect` que el commit actual es **GOOD** (correcto/pasa).
  * **Código de salida `1` a `127` (excepto 125)**: Señala que el commit es **BAD** (fallo / regresión presente).
  * **Código de salida `125`**: Señala que el commit es **UNTESTABLE** (no testeable / omitir). `git bisect` omite este commit y selecciona un commit adyacente en el grafo DAG.

* **3.2 Respuesta:**  
  De forma predeterminada, `git bisect` recorre el DAG topológico a través de todas las rutas de los padres de los commits de fusión. Si las ramas de características (feature branches) se fusionaron mediante topologías de fusión no lineales que contienen commits defectuosos dentro de ramas secundarias, `git bisect` desciende a los historiales de las ramas para ubicar el commit exacto que causó la falla.  
  Si un commit de fusión en sí introdujo un error de resolución de conflictos (donde el padre A y el padre B eran ambos buenos, pero el resultado de la fusión rompió el código), `git bisect` identifica correctamente el hash del commit de fusión como el punto de regresión.

---

### Respuestas al Ejercicio 4

* **4.1 Respuesta:**  
  * Los hooks `pre-commit` se ejecutan en la estación de trabajo local del desarrollador. Cualquier cliente los puede omitir fácilmente ejecutando `git commit --no-verify` o eliminando `.git/hooks/pre-commit`. No se puede confiar en ellos para obtener garantías de seguridad o cumplimiento organizacional.
  * Los hooks `pre-receive` se ejecutan en el servidor central remoto de Git (ej., GitHub Enterprise, GitLab, servidor bare). Se ejecutan dentro de un entorno de servidor aislado antes de que se actualicen las referencias. Los desarrolladores **no** pueden omitir los hooks `pre-receive` independientemente de las flags de la CLI del cliente, lo que los hace obligatorios para las políticas de seguridad empresariales.

* **4.2 Respuesta:**  
  1. `pre-receive`: Se ejecuta **una vez** por transacción de push. Acepta la entrada estándar que contiene todas las actualizaciones de referencias propuestas (`old-sha new-sha ref-name`). Si finaliza con un valor distinto de cero, **se aborta todo el push** y no se actualiza ninguna referencia.
  2. `update`: Se ejecuta **una vez por rama/referencia actualizada**. Acepta los argumentos: `<ref-name> <old-sha> <new-sha>`. Si finaliza con un valor distinto de cero para una referencia específica, **solo se rechaza la actualización de esa referencia**.
  3. `post-receive`: Se ejecuta **una vez** después de que todas las referencias se hayan actualizado con éxito en el disco. Se utiliza para notificaciones asincrónicas (Slack, disparador de CI/CD). **No** puede rechazar ni abortar la transacción de push.

---

### Respuestas al Ejercicio 5

* **5.1 Respuesta:**  
  El modo `160000` es un modo de directorio especial de Git que representa un **Gitlink** (referencia vinculante de commit de submódulo). Un repositorio anfitrión no almacena directamente los archivos del submódulo; registra un hash de commit estático de 40 caracteres que apunta a un objeto commit exacto dentro del repositorio del submódulo remoto. Esto desacopla el ciclo de vida del anfitrión del ciclo de vida del módulo.

* **5.2 Respuesta:**  
  De forma predeterminada, `git clone` solo recupera los objetos tree del repositorio anfitrión y los SHAs de gitlink (`160000`), dejando vacíos los directorios de los submódulos.  
  Para poblar los submódulos durante el clonado inicial:  
  `git clone --recurse-submodules <url>`  
  Si el repositorio ya fue clonado:  
  `git submodule init` seguido de `git submodule update` (o `git submodule update --init --recursive`).

</details>

---

## 4. Lista de Verificación Resumida Clave para LPI 701-100 Tema 1.3

- [x] Comprender la estructura de almacenamiento de objetos internos de Git (`.git/objects/`, `blob`, `tree`, `commit`, `tag`).
- [x] Dominar los comandos de inspección plumbing: `git cat-file`, `git hash-object`, `git write-tree`, `git update-index`, `git update-ref`.
- [x] Diferenciar los modos de reset: `--soft`, `--mixed`, `--hard` y la recuperación de referencias mediante `git reflog`.
- [x] Automatizar el aislamiento de regresiones usando `git bisect run <script_path>` y manejar el código de salida `125`.
- [x] Implementar hooks del lado del servidor (`pre-receive`, `update`, `post-receive`) para hacer cumplir el escaneo de secretos y el cumplimiento de políticas.
- [x] Utilizar `git worktree` para cambiar de espacio de trabajo contextual sin sobrecarga ni contaminación de stash.
- [x] Gestionar submódulos de Git, gitlinks de modo `160000`, especificaciones de `.gitmodules` y la mecánica de clonación `--recurse-submodules`.