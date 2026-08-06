# Tema 6.2: Gestión de Código Fuente (SCM) — Guía de Estudio de Nivel de Producción

---

## 1. Motivación Arquitectónica y Planteamiento del Problema de Producción

En la Ingeniería de Confiabilidad de Sitios (SRE) moderna y la gestión de Infraestructura Cloud Native, el software y las configuraciones de infraestructura existen como artefactos dinámicos y en constante mutación. Sin un versionado riguroso y una gobernanza centralizada, las flotas de desarrollo distribuido inevitablemente se enfrentan a fallas operativas críticas:

1. **Peligros de Concurrencia y Condiciones de Carrera de Estado:** Las alteraciones simultáneas en las configuraciones de producción (por ejemplo, manifiestos de Kubernetes, archivos de estado de Terraform, lógica de aplicación) causan derivas de despliegue (deployment drift), entornos de split-brain e interrupciones del servicio (outages) irrecursables.
2. **Despliegues No Reproducibles:** La incapacidad de fijar los estados de ejecución a commits criptográficos exactos conduce a builds no deterministas y a fallas en la depuración posterior al despliegue.
3. **Déficits de Auditabilidad y Cumplimiento:** Los marcos regulatorios (SOC2, ISO 27001, HIPAA) exigen una procedencia inmutable y criptográficamente verificable de cada línea de código desplegada en producción.
4. **Exposición a la Seguridad de la Cadena de Suministro:** El código fuente no firmado o no validado permite la inyección no autorizada de artefactos maliciosos en los pipelines de CI/CD automatizados.

### El Modelo de Almacenamiento y Arquitectura: SCM Distribuido vs. Centralizado

Los sistemas de Gestión de Código Fuente (SCM) proporcionan persistencia de estado, seguimiento histórico y colaboración concurrente. Comprender el cambio estructural del VCS Centralizado (CVCS) al SCM Distribuido (DVCS) es fundamental para la arquitectura cloud-native.

```
Centralized SCM (e.g., SVN, Perforce)        Distributed SCM (e.g., Git)
=====================================        ===========================

     +-----------------------+                    +-----------------------+
     | Central Repository    |                    | Remote Repository     |
     | (Full Commit History) |                    | (Full Commit History) |
     +-----------+-----------+                    +-----------+-----------+
                 |                                            ^
  Network Commit | Checkout (Working Copy Only)   Push/Pull   | Local Offline
                 v                                            v Operations
        +--------+--------+                      +------------+-----------+
        | Developer Node  |                      | Developer Node           |
        | (No Local Hist) |                      | (Full DAG Repository Copy)|
        +-----------------+                      +------------------------+
```

* **Sistemas Centralizados (SVN, Perforce):** Dependen de un único servidor de base de datos autoritativo. El espacio de trabajo del desarrollador mantiene solo una copia de trabajo transitoria de una sola revisión. Las operaciones atómicas (commit, log, diff, branch) requieren conectividad de red continua con el host central. Una falla del servidor central detiene todos los flujos de trabajo de ingeniería.
* **Sistemas Distribuidos (Git):** Cada clon es un repositorio totalmente funcional y autónomo que lleva todo el historial del Grafo Acíclico Dirigido (DAG) criptográfico. Los commits, la creación de ramas, la generación de diffs y las auditorías históricas ocurren localmente a baja latencia y sin dependencia de la red. Los repositorios remotos funcionan meramente como puntos finales de coordinación sincronizados.

### Modelo de Objetos e Internos de Git

Git almacena la información como una base de datos de objetos clave-valor direccionable por contenido dentro del directorio `.git/objects`. La clave primaria para cualquier objeto es el hash criptográfico SHA-1 de 40 caracteres (o SHA-256 de 64 caracteres) calculado sobre `type + payload_length + \0 + payload`.

```
                +-------------------+
                |   Commit Object   |
                |  (SHA: a1b2c3d)   |
                +---------+---------+
                          |
             +------------+------------+
             | Tree (Root Directory)   |
             |     (SHA: e5f6a7b)      |
             +------------+------------+
                          |
         +----------------+----------------+
         |                                 |
+--------+--------+               +--------+--------+
| Tree (src/)     |               | Blob (README.md)|
| (SHA: c9d8e7f)  |               | (SHA: f1e2d3c)  |
+--------+--------+               +-----------------+
         |
+--------+--------+
| Blob (main.go)  |
| (SHA: b4a5c6d)  |
+-----------------+
```

1. **Blob (Binary Large Object):** Almacena contenido de archivo sin procesar sin metadatos (se omiten el nombre de archivo, los permisos y las marcas de tiempo).
2. **Tree:** Representa estructuras de directorios. Mantiene referencias a blobs hijos o sub-trees anidados, mapeados a nombres de archivo, modos de ejecución (`100644` archivo estándar, `100755` ejecutable, `040000` subdirectorio) y hashes SHA-1 de los objetos.
3. **Commit:** Apunta a un hash de objeto `Tree` raíz. Contiene metadatos incluyendo el hash del commit (o commits) padre, autor, committer, marca de tiempo de Unix, zona horaria y mensaje de log.
4. **Annotated Tag:** Apunta a un objeto commit específico. Contiene metadatos explícitos del tagger, firma GPG opcional y mensaje.

---

## 2. Comparativas Técnicas y Tablas de Compromiso (Trade-off Tables)

### Matriz 1: Paradigmas de Arquitectura de Control de Versiones

| Característica / Métrica | VCS Centralizado (SVN) | SCM Distribuido (Git) | Plataforma Monorepo (Git + LFS / Scalar) |
| :--- | :--- | :--- | :--- |
| **Topología del Historial** | Lineal / Servidor Central | Grafo Acíclico Dirigido (DAG) | DAG Virtualizado Híbrido |
| **Dependencia de Red** | Obligatoria para todas las operaciones excepto edición | Red requerida solo para `fetch`/`push` | Red requerida para objetos virtuales no en caché |
| **Costo de Ramas (Branch)** | Sobrecarga de copia en sistema de archivos $O(N)$ | Actualización de puntero $O(1)$ (41 bytes) | Actualización de puntero $O(1)$ |
| **Manejo de Activos Binarios** | Reserva nativa basada en bloqueos | Pobre manejo nativo (sobrepeso del repositorio) | Gestionado mediante redirección de punteros LFS |
| **Complejidad de Almacenamiento** | Almacenamiento Delta en el lado del servidor | Base de Datos de Objetos + Packfiles en el lado del cliente | Sparse Checkouts + File System Monitor |
| **Integridad Criptográfica** | IDs de Revisión (Enteros Secuenciales) | Hashing de Contenido SHA-1 / SHA-256 | Hashing de Contenido SHA-256 |

---

### Matriz 2: Estrategias de Ramificación Enterprise

| Estrategia | Estructura | Caso de Uso Ideal | Pros | Contras |
| :--- | :--- | :--- | :--- | :--- |
| **Trunk-Based Development** | Rama `main` única, ramas de características (feature branches) de corta duración (<24h) | Microservicios de alta velocidad, Despliegue Continuo (CD) | Previene la deuda de integración (merge debt), acelera la entrega | Requiere alta cobertura de pruebas y feature flags |
| **GitFlow** | `main` de larga duración, `develop`, `feature/*`, `release/*`, `hotfix/*` | Software monolítico legado, ciclos de lanzamiento programados | Gobernanza estructurada, lanzamientos aislados | Deuda de integración severa, compleja sobrecarga de integración |
| **GitHub Flow** | `main` de larga duración, ramas de tema de corta duración + revisión de código en PR | Aplicaciones SaaS, Entrega Continua | Modelo mental simple, revisión por pares obligatoria | No apto para mantenimiento concurrente de múltiples versiones |
| **GitLab Flow** | Rama `main` emparejada con ramas de entorno (`staging`, `prod`) | Puertas de despliegue impulsadas por el entorno | Mapeo explícito de ramas a clusters | Riesgo de deriva de configuración entre entornos |

---

### Matriz 3: Mecánica de Integración (`merge` vs `rebase` vs `cherry-pick`)

| Comando | Resultado en el Historial | ¿Merge Commit Creado? | Manejo de Conflictos | Factor de Riesgo SRE |
| :--- | :--- | :--- | :--- | :--- |
| `git merge --no-ff` | Preserva la topología histórica real | Sí | Resuelto una vez por evento de merge | Bajo: Historial no destructivo y transparente |
| `git merge --ff-only` | Mueve el puntero de la rama hacia adelante | No | Falla si el historial ha divergido | Bajo: Falla de forma segura si no es lineal |
| `git rebase` | Reescribe el historial sobre un nuevo commit base | No | Resuelto iterativamente por cada commit reescrito | Medio/Alto: Altera los SHAs de los commits; rompe ramas compartidas |
| `git cherry-pick` | Duplica un commit específico en el HEAD actual | No | Resuelto en el punto de invocación | Alto: Crea commits lógicos duplicados con SHAs distintos |

---

## 3. Manifiestos de Producción Completos y Configuraciones de Infraestructura

### 3.1 Configuración Global del Entorno SRE (`.gitconfig`)

Guardar como `~/.gitconfig` o `/etc/gitconfig` en agentes de build enterprise endurecidos:

```ini
[user]
    name = SRE Platform Automation
    email = sre-bot@infrastructure.internal
    signingkey = 3AA5C1F82D9E7B10

[core]
    autocrlf = input
    eol = lf
    filemode = true
    whitespace = error-at-eol,space-before-tab,tab-in-indent
    excludesfile = ~/.gitignore_global
    fsmonitor = true
    untrackedCache = true

[commit]
    gpgsign = true
    template = ~/.gitmessage.txt

[tag]
    gpgsign = true

[gpg]
    program = gpg

[init]
    defaultBranch = main

[pull]
    rebase = true

[push]
    default = simple
    followTags = true
    autoSetupRemote = true

[rebase]
    autoSquash = true
    autoStash = true
    missingCommitsCheck = error

[merge]
    ff = false
    conflictstyle = zdiff3

[diff]
    algorithm = histogram
    colorWords = true
    renames = copies

[transfer]
    fsckObjects = true

[fetch]
    fsckObjects = true
    prune = true
    pruneTags = true

[receive]
    fsckObjects = true
```

---

### 3.2 `.gitignore` Multi-Stack Enterprise

Guardar como `.gitignore` en la raíz del repositorio:

```gitignore
# Core OS & Editor Temp Artifacts
.DS_Store
Thumbs.db
*~
*.swp
*.swo

# Sensitive Cloud Credentials & Secrets Protection
*.pem
*.key
*.p12
*.pfx
id_rsa
id_ed25519
*.tfvars
*.tfvars.json
.env
.env.*
!.env.example
secrets.yaml
secrets.json

# Infrastructure & Terraform Artifacts
.terraform/
*.tfstate
*.tfstate.backup
.terraform.lock.hcl
crash.log

# Kubernetes & Helm Artifacts
.helm/
helm-drawer/
*.tpl.bak

# Node.js / Frontend Stack
node_modules/
npm-debug.log*
yarn-debug.log*
yarn-error.log*
.pnpm-debug.log*
dist/
build/
.next/

# Python / Automation Stack
__pycache__/
*.py[cod]
*$py.class
.venv/
venv/
ENV/
build/
develop-eggs/
dist/
downloads/
eggs/
.eggs/
*.egg-info/
.pytest_cache/
.coverage

# Go Stack
/bin/
/pkg/
*.exe
*.test
*.prof
coverage.out

# Binary Data & Large Asset Catch Block
*.iso
*.tar.gz
*.7z
*.zip
*.sqlite3
```

---

### 3.3 Hook de Pre-commit Automatizado para Seguridad del Lado del Cliente y Linting

Guardar como `.git/hooks/pre-commit`, luego ejecutar `chmod +x .git/hooks/pre-commit`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Color Codes for Output Formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}[PRE-COMMIT] Initiating SRE Source Code Management Security Inspections...${NC}"

# Step 1: Detect Staged Secret Exposure
STAGED_FILES=$(git diff --cached --name-only --diff-filter=ACM)

if [ -z "$STAGED_FILES" ]; then
    echo -e "${GREEN}[PRE-COMMIT] No staged files detected. Skipping check.${NC}"
    exit 0
fi

# Secret Pattern Scanning
SECRET_PATTERNS="(AWS_SECRET_ACCESS_KEY|AWS_ACCESS_KEY_ID|ghp_[a-zA-Z0-9]{36}|BEGIN PRIVATE KEY|AKIA[0-9A-Z]{16})"

for FILE in $STAGED_FILES; do
    if [ -f "$FILE" ]; then
        if grep -E -q "$SECRET_PATTERNS" "$FILE"; then
            echo -e "${RED}[SECURITY ALERT] Potential plaintext secret detected in: $FILE${NC}"
            echo -e "${RED}Aborting commit. Sanitize credentials or use an external secret vault.${NC}"
            exit 1
        fi
    fi
done

# Step 2: Validate Syntax / Linting for YAML and Shell Files
for FILE in $STAGED_FILES; do
    if [[ "$FILE" =~ \.(yaml|yml)$ ]] && [ -f "$FILE" ]; then
        if command -v yq >/dev/null 2>&1; then
            yq eval '.' "$FILE" >/dev/null 2>&1 || {
                echo -e "${RED}[SYNTAX ERROR] Invalid YAML manifest: $FILE${NC}"
                exit 1
            }
        fi
    elif [[ "$FILE" =~ \.sh$ ]] && [ -f "$FILE" ]; then
        if command -v shellcheck >/dev/null 2>&1; then
            shellcheck "$FILE" || {
                echo -e "${RED}[LINT ERROR] Shellcheck validation failed: $FILE${NC}"
                exit 1
            }
        fi
    fi
done

# Step 3: Prevent Staging Conflict Markers
for FILE in $STAGED_FILES; do
    if [ -f "$FILE" ]; then
        if grep -E -q "^(<<<<<<<|=======|>>>>>>>)" "$FILE"; then
            echo -e "${RED}[MERGE CONFLICT ERROR] Unresolved conflict markers found in: $FILE${NC}"
            exit 1
        fi
    fi
done

echo -e "${GREEN}[PRE-COMMIT] All SRE pre-commit compliance checks passed successfully.${NC}"
exit 0
```

---

### 3.4 Workflow de Gobernanza SCM de GitHub Actions

Guardar como `.github/workflows/scm-governance.yml`:

```yaml
name: SCM Compliance & Code Provenance Governance

on:
  pull_request:
    branches: [ main ]
    types: [ opened, synchronize, reopened ]
  push:
    branches: [ main ]

jobs:
  scm-compliance:
    name: Validate Commit Signature and History Integrity
    runs-on: ubuntu-latest

    steps:
      - name: Checkout Code Base
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Enforce Linear History and Fast-Forward Capability
        run: |
          echo "Checking branch topology against origin/main..."
          BEHIND_COUNT=$(git rev-list --count HEAD..origin/main)
          if [ "$BEHIND_COUNT" -ne 0 ]; then
            echo "::error::PR branch is behind origin/main by $BEHIND_COUNT commits. Rebase required."
            exit 1
          fi

      - name: Scan Repository for Exposed Credentials (Gitleaks)
        uses: gitleaks/gitleaks-action@v2
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

      - name: Validate Commit Message Format (Conventional Commits)
        run: |
          COMMIT_MSG=$(git log -1 --pretty=format:"%s")
          CONVENTIONAL_REGEX="^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([a-z0-9\--_]+\))?: .+$"
          if [[ ! "$COMMIT_MSG" =~ $CONVENTIONAL_REGEX ]]; then
            echo "::error::Commit message '$COMMIT_MSG' does not adhere to Conventional Commits format."
            echo "Example: feat(api): add health check endpoint"
            exit 1
          fi

      - name: Verify Signed Commits
        run: |
          UNSIGNED_COMMITS=0
          for commit in $(git rev-list origin/main..HEAD); do
            if ! git verify-commit "$commit" >/dev/null 2>&1; then
              echo "Warning: Commit $commit is unsigned or missing valid GPG/SSH key."
              UNSIGNED_COMMITS=$((UNSIGNED_COMMITS + 1))
            fi
          done
          if [ "$UNSIGNED_COMMITS" -gt 0 ]; then
            echo "::error::$UNSIGNED_COMMITS unsigned commit(s) detected in PR chain."
            exit 1
          fi
```

---

## 4. Comandos CLI Reales y Salidas de Ejecución en Terminal

### 4.1 Comandos Plumbing y Hashing de Objetos Internos

#### Comando: Inicializando un Repositorio Vacío e Inspeccionando el Estado Interno

```bash
$ mkdir sre-scm-lab && cd sre-scm-lab
$ git init
```

```output
Initialized empty Git repository in /home/operator/sre-scm-lab/.git/
```

#### Comando: Creando un Objeto Blob Directamente a Través de la Herramienta Plumbing (`hash-object`)

```bash
$ echo "Cloud Native Infrastructure State Engine" | git hash-object -w --stdin
```

```output
d98ca68c8b417c88b90a4dfb7d8d212df8b1a8d4
```

#### Comando: Inspeccionando el Tipo de Objeto y el Tamaño del Archivo en el Almacenamiento de Objetos (`cat-file`)

```bash
$ git cat-file -t d98ca68c8b417c88b90a4dfb7d8d212df8b1a8d4
```

```output
blob
```

```bash
$ git cat-file -p d98ca68c8b417c88b90a4dfb7d8d212df8b1a8d4
```

```output
Cloud Native Infrastructure State Engine
```

#### Comando: Inspeccionando el Contenido del Directorio Bajo `.git/objects`

```bash
$ find .git/objects -type f
```

```output
.git/objects/d9/8ca68c8b417c88b90a4dfb7d8d212df8b1a8d4
```

---

### 4.2 Construyendo un Árbol DAG y un Objeto Commit Manualmente

#### Comando: Creando un Archivo, Staging y Examinando el Índice de Staging

```bash
$ echo "service: payment-gateway" > config.yaml
$ git add config.yaml
$ git ls-files --stage
```

```output
100644 e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 0	config.yaml
```

#### Comando: Escribiendo el Índice en un Objeto Tree (`write-tree`)

```bash
$ TREE_HASH=$(git write-tree)
$ echo $TREE_HASH
```

```output
6f88ec4c8bb1261d7b37042a35368a514d2325ab
```

#### Comando: Leyendo la Estructura de un Objeto Tree (`ls-tree`)

```bash
$ git ls-tree 6f88ec4c8bb1261d7b37042a35368a514d2325ab
```

```output
100644 blob e69de29bb2d1d6434b8b29ae775ad8c2e48c5391	config.yaml
```

#### Comando: Creando un Objeto Commit que Apunta al Tree (`commit-tree`)

```bash
$ COMMIT_HASH=$(echo "feat(config): initial payment service architecture" | git commit-tree $TREE_HASH)
$ echo $COMMIT_HASH
```

```output
a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6
```

#### Comando: Actualizando el Puntero de Rama (`HEAD`) al Nuevo Commit (`update-ref`)

```bash
$ git update-ref refs/heads/main $COMMIT_HASH
$ git log --oneline
```

```output
a7b8c9d (HEAD -> main) feat(config): initial payment service architecture
```

---

### 4.3 Rebase Interactivo, Squashing del Historial y Operaciones con Ramas

#### Comando: Creando un Historial Divergente para Demostración

```bash
$ git checkout -b feature/auth-service
$ echo "auth_provider: oauth2" >> auth.yaml && git add auth.yaml && git commit -m "feat(auth): add oauth config"
$ echo "timeout: 30s" >> auth.yaml && git add auth.yaml && git commit -m "fix(auth): adjust timeout parameter"
$ echo "retry_limit: 3" >> auth.yaml && git add auth.yaml && git commit -m "chore(auth): set default retries"
$ git log --oneline -n 3
```

```output
8f7e6d5 (HEAD -> feature/auth-service) chore(auth): set default retries
3c2b1a4 fix(auth): adjust timeout parameter
9a8b7c6 feat(auth): add oauth config
```

#### Comando: Ejecutando Rebase Autosquash No Interactivo para Consolidar el Historial

```bash
$ GIT_SEQUENCE_EDITOR="sed -i -e '2,3s/^pick/squash/'" git rebase -i HEAD~3
```

```output
[detached HEAD c4d3e2f] feat(auth): add oauth config
 Date: Thu Aug 6 19:30:00 2026 -0400
 1 file changed, 3 insertions(+)
 create mode 100644 auth.yaml
Successfully rebased and updated refs/heads/feature/auth-service.
```

#### Comando: Inspeccionando la Topografía Limpia del Log

```bash
$ git log --oneline -n 2
```

```output
c4d3e2f (HEAD -> feature/auth-service) feat(auth): add oauth config
a7b8c9d (main) feat(config): initial payment service architecture
```

---

### 4.4 Integración Fast-Forward vs Merge Non-Fast-Forward

#### Comando: Aplicación de Fast-Forward (`git merge --ff-only`)

```bash
$ git checkout main
$ git merge --ff-only feature/auth-service
```

```output
Updating a7b8c9d..c4d3e2f
Fast-forward
 auth.yaml | 3 +++
 1 file changed, 3 insertions(+)
 create mode 100644 auth.yaml
```

#### Comando: Verificando el Grafo del Repositorio

```bash
$ git log --graph --oneline --all
```

```output
* c4d3e2f (HEAD -> main, feature/auth-service) feat(auth): add oauth config
* a7b8c9d feat(config): initial payment service architecture
```

---

## 5. Guía de Verificación, Diagnóstico de Fallas y Recuperación ante Desastres

### 5.1 Matriz de Decisión de Diagnóstico SRE para Fallas de SCM

```
                    +----------------------------------+
                    | Incident Reported / Build Failed |
                    +----------------+-----------------+
                                     |
                                     v
                       Is HEAD detached or commit lost?
                       /                              \
                     YES                               NO
                     /                                  \
         +----------+----------+               +--------+--------+
         | Execute git reflog  |               | Are conflict    |
         | Identify lost hash  |               | markers present?|
         | Re-attach pointer   |               +--------+--------+
         +---------------------+                        |
                                               +--------+--------+
                                              YES                NO
                                              /                   \
                                   +---------+---------+   +-------+-------+
                                   | Run 3-way merge   |   | Automated     |
                                   | diff editor       |   | Regression    |
                                   | Resolve & commit  |   | Bisect Search |
                                   +-------------------+   +---------------+
```

---

### 5.2 Estudio de Caso 1: Recuperación de un `Detached HEAD` y Commits Huérfanos (Dangling Commits)

#### Escenario de Diagnóstico

Un agente de build de CI ejecuta un checkout a un hash de commit sin procesar en lugar de un nombre de rama. El desarrollador ejecuta cambios estructurales y realiza commits localmente. Al ejecutar `git checkout main`, el directorio de trabajo vuelve a cambiar, dejando el nuevo commit desvinculado de cualquier referencia nombrada (`refs/heads/`).

#### Paso 1: Detectar el Estado Actual

```bash
$ git status
```

```output
HEAD detached at 7d8c9b0
nothing to commit, working tree clean
```

```bash
$ git checkout main
```

```output
Warning: you are leaving 1 commit behind, not connected to
any of your branches:

  7d8c9b0 feat(security): critical hotfix applied detached

If you want to keep them by creating a new branch, this may be a good time
to do so with:

  git branch <new-branch-name> 7d8c9b0

Switched to branch 'main'
```

#### Paso 2: Extraer el Hash del Commit Perdido a Través del Log de Referencias (`reflog`)

El `reflog` rastrea los ajustes de punteros locales (`HEAD`, ramas) en `.git/logs/HEAD`.

```bash
$ git reflog -n 5
```

```output
c4d3e2f (HEAD -> main) HEAD@{0}: checkout: moving from 7d8c9b0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e to main
7d8c9b0 HEAD@{1}: commit: feat(security): critical hotfix applied detached
c4d3e2f (HEAD -> main) HEAD@{2}: checkout: moving from main to 7d8c9b0
```

#### Paso 3: Ejecutar la Verificación de Integridad de la Base de Datos (`git fsck`) para Verificar Objetos Huérfanos

```bash
$ git fsck --lost-found
```

```output
Checking object directories: 100% (256/256), done.
dangling commit 7d8c9b0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e
```

#### Paso 4: Re-vincular el Commit Huérfano a un Puntero de Referencia Funcional

```bash
$ git branch recovery/hotfix-branch 7d8c9b0
$ git log --oneline -n 1 recovery/hotfix-branch
```

```output
7d8c9b0 (recovery/hotfix-branch) feat(security): critical hotfix applied detached
```

```bash
$ git merge --no-ff recovery/hotfix-branch -m "merge: recover detached security hotfix"
```

---

### 5.3 Estudio de Caso 2: Resolución de Conflictos de Merge de Tres Vías (Three-Way Merge) Complejos

#### Escenario de Diagnóstico

Dos despliegues de producción concurrentes modifican la misma línea en `deploy.env`.

* Rama `main`: `REPLICAS=3`
* Rama `feature/scaling`: `REPLICAS=10`

Ejecutar `git merge feature/scaling` activa un conflicto explícito.

#### Salida de Terminal

```bash
$ git merge feature/scaling
```

```output
Auto-merging deploy.env
CONFLICT (content): Merge conflict in deploy.env
Automatic merge failed; fix conflicts and then commit the result.
```

#### Paso 1: Examinar el Estado del Archivo en Conflicto

```bash
$ cat deploy.env
```

```output
<<<<<<< HEAD
REPLICAS=3
=======
REPLICAS=10
>>>>>>> feature/scaling
```

#### Paso 2: Utilizar el Estilo de Conflicto `zdiff3` para un Contexto Detallado

Configurar `zdiff3` para mostrar el bloque del ancestro común, destacando el estado base original:

```bash
$ git config local merge.conflictstyle zdiff3
$ git checkout --merge deploy.env
$ cat deploy.env
```

```output
<<<<<<< HEAD
REPLICAS=3
||||||| base-ancestor
REPLICAS=1
=======
REPLICAS=10
>>>>>>> feature/scaling
```

#### Paso 3: Resolver Programáticamente y Completar el Merge

```bash
# Choose 10 based on capacity requirements
$ echo "REPLICAS=10" > deploy.env
$ git add deploy.env
$ git commit --no-edit
```

```output
[main a1b2c3d] Merge branch 'feature/scaling' into main
```

---

### 5.4 Estudio de Caso 3: Bisección de Regresión Automatizada (`git bisect`)

#### Escenario de Diagnóstico

Ocurrió una degradación silenciosa del rendimiento en algún lugar entre la etiqueta `v2.0.0` (conocido como bueno) y `HEAD` (conocido como malo, a lo largo de 400 commits).

#### Paso 1: Inicializar el Motor de Bisección

```bash
$ git bisect start
$ git bisect bad HEAD
$ git bisect good v2.0.0
```

```output
Bisecting: 199 revisions left to test after this (roughly 8 steps)
[e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3] feat(mesh): update sidecar proxy settings
```

#### Paso 2: Ejecutar el Script de Bisección Automatizado

Ejecutar un script de prueba automatizado (`test.sh`) que devuelve el código de salida `0` (bueno) o distinto de cero (malo):

```bash
$ git bisect run ./test.sh
```

```output
running ./test.sh
Bisecting: 99 revisions left to test after this (roughly 7 steps)
...
running ./test.sh
e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3 is the first bad commit
commit e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3
Author: SRE Automation <sre@internal>
Date:   Wed Aug 5 14:22:10 2026 -0400

    perf(db): lower connection pool size limit

 bisect run success
```

#### Paso 3: Restablecer el Repositorio al Estado Operativo

```bash
$ git bisect reset
```

```output
Previous HEAD position was e4f5a6b feat(mesh): update sidecar proxy settings
Switched to branch 'main'
```

---

### 5.5 Estudio de Caso 4: Corrupción de Base de Datos y Depuración Profunda de Secretos (Hard Secret Scrubbing)

#### Escenario de Diagnóstico

Un desarrollador cometió accidentalmente una clave de acceso secreta de AWS no encriptada (`AKIAIOSFODNN7EXAMPLE`) hace 50 commits. Un simple `git rm` elimina el archivo del HEAD actual, pero deja el secreto accesible en commits históricos a través del recorrido de la base de datos de objetos.

#### Paso 1: Buscar el Secreto en Todos los Commits Históricos

```bash
$ git log -S "AKIAIOSFODNN7EXAMPLE" --oneline
```

```output
4b3c2a1 feat(cloud): configure AWS S3 storage provider backend
```

#### Paso 2: Purgar el Archivo/Cadena de Forma Permanente Usando `git-filter-repo`

*Nota: El `git filter-branch` nativo está obsoleto debido a riesgos de rendimiento e integridad. `git-filter-repo` es la herramienta estándar moderna.*

```bash
# Execute string replacement across the entire history DAG
$ git filter-repo --replace-text <(echo "AKIAIOSFODNN7EXAMPLE==>REDACTED_AWS_KEY") --force
```

```output
Parsed 51 commits
New history written in 0.42 seconds; retrofitted 51 commits.
completely finished.
```

#### Paso 3: Forzar la Recolección de Basura (Garbage Collection) y la Expiración del Reflog

Purgar objetos sueltos no referenciados para eliminar datos residuales del disco:

```bash
$ git reflog expire --expire=now --expire-unreachable=now --all
$ git gc --prune=now --aggressive
```

```output
Enumerating objects: 153, done.
Counting objects: 100% (153/153), done.
Delta compression using up to 16 threads
Compressing objects: 100% (120/120), done.
Writing objects: 100% (153/153), done.
Total 153 (delta 42), reused 98 (delta 0), pack-reused 0
```

#### Paso 4: Verificar la Eliminación en la Base de Datos

```bash
$ git log -S "AKIAIOSFODNN7EXAMPLE" --oneline
```

```output
(No results returned)
```

---

## 6. Referencias

* **Linux Professional Institute (LPI) Open Source Essentials Overview:**  
  [https://www.lpi.org/our-certifications/open-source-essentials-overview/](https://www.lpi.org/our-certifications/open-source-essentials-overview/)
* **Official Git Documentation & Internals Specification:**  
  [https://git-scm.com/docs](https://git-scm.com/docs)
* **Git Book: Git Community Plumbing and Porcelain Internals:**  
  [https://git-scm.com/book/en/v2/Git-Internals-Git-Objects](https://git-scm.com/book/en/v2/Git-Internals-Git-Objects)
* **CNCF Webhooks & Security Best Practices for SCM Pipelines:**  
  [https://www.cncf.io/reports/](https://www.cncf.io/reports/)
* **git-filter-repo Documentation & Security Scrubbing:**  
  [https://github.com/newren/git-filter-repo](https://github.com/newren/git-filter-repo)