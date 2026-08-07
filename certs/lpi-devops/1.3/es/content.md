# LPI DevOps Tools Engineer (701-100) — Topic 701.3: Source Code Management

---

## 1. Motivación Arquitectónica en Producción y Mecánica Interna

### 1.1 Source Code Management (SCM) Centralizado vs. Distribuido
En entornos empresariales heredados (legacy), los sistemas de SCM Centralizados (como Subversion/SVN y CVS) operaban sobre una arquitectura cliente-servidor con una única base de datos central autoritativa. Las operaciones como la inspección del historial (`svn log`), la generación de diffs (`svn diff`) y las operaciones de commit requerían trayectos de red (round-trips) al servidor del repositorio central. Los sistemas centralizados imponen el bloqueo de archivos (checkout exclusivo) o resoluciones de merge del lado del servidor, introduciendo riesgos de punto único de falla (SPOF), cuellos de botella por latencia de red y severos límites de escalabilidad cuando los pipelines de CI/CD generan cientos de operaciones de lectura/escritura concurrentes.

La ingeniería de plataformas cloud-native moderna se basa en SCM Distribuido (Git). En Git, cada clon local es un repositorio completamente funcional que contiene el historial completo de commits, la base de datos de objetos y los metadatos de ref. Esta descentralización permite:
- **Autonomía Offline:** Los desarrolladores y pipelines automatizados pueden realizar commits, crear ramas (branching), hacer rebase e inspeccionar el historial sin dependencias de red.
- **Alta Concurrencia:** Las operaciones de lectura se ejecutan localmente con cero sobrecoste de red; la interacción con la red ocurre de forma asíncrona mediante fetches y pushes de red empaquetados por deltas.
- **Resistencia Criptográfica a Manipulaciones:** Todos los estados están representados dentro de un Grafo Acíclico Dirigido (DAG) de solo anexado (append-only) protegido por hashing criptográfico.

---

### 1.2 Mecánica Interna de Git y DAG de la Base de Datos de Objetos
Git opera como un sistema de archivos clave-valor direccionable por contenido subyacente a un sistema de control de versiones de alto nivel. Todos los objetos dentro de `.git/objects/` son inmutables y están identificados por un hash SHA-1 de 40 caracteres (o SHA-256 de 64 caracteres) calculado a partir del tipo de objeto, la longitud del contenido, un delimitador de byte nulo y el contenido de la carga útil (payload).

```
       +-------------------------------------------------------------+
       |                     Commit Object                           |
       |  SHA: 8f3a1d...                                             |
       |  tree: e9a2b4...                                            |
       |  parent: 4c1d8e...                                          |
       |  author: Dev <dev@company.com>                              |
       |  committer: CI <ci@company.com>                             |
       |                                                             |
       |  feat(api): implement auth middleware                       |
       +------------------------------+------------------------------+
                                      |
                                      v
                       +--------------+---------------+
                       |   Root Tree Object (e9a2b4)  |
                       |  100644 blob a1b2c3... src/  |
                       |  040000 tree d4e5f6... app/  |
                       +--------------+---------------+
                                      |
              +-----------------------+-----------------------+
              |                                               |
              v                                               v
+-------------+----------------+               +--------------+---------------+
|   Blob Object (a1b2c3)       |               | Sub-Tree Object (d4e5f6)     |
|   (src/main.go)              |               | (app/)                       |
|   package main               |               | 100644 blob f7e8d9... server |
|   ...                        |               +--------------+---------------+
+------------------------------+                              |
                                                              v
                                               +--------------+---------------+
                                               |   Blob Object (f7e8d9)       |
                                               |   (app/server.go)            |
                                               +------------------------------+
```

Git gestiona cuatro tipos de objetos primarios dentro del almacenamiento de objetos (object store):

1. **Blob (`blob`):** Almacena datos de archivos en bruto (raw) sin metadatos de archivo, permisos, estructura de directorios ni nombres de archivo. Dos archivos idénticos en cualquier lugar del repositorio apuntan exactamente al mismo SHA de blob.
2. **Tree (`tree`):** Representa estructuras de directorios. Un objeto tree contiene punteros a entradas de directorio que consisten en modos de archivo POSIX (`100644` para archivos estándar, `100755` para ejecutables, `040000` para subdirectorios), tipos de objeto, hashes SHA y nombres de archivo/directorio.
3. **Commit (`commit`):** Apunta a un objeto tree raíz, cero o más SHAs de commits padres (cero para el commit raíz, uno para un commit estándar, dos o más para merge commits), marca de tiempo del autor, marca de tiempo del committer y el mensaje de commit.
4. **Annotated Tag (`tag`):** Apunta a un SHA de commit específico (o a cualquier objeto), conteniendo la identidad del tagger, marca de tiempo, firma GPG y un mensaje explícito.

---

### 1.3 Packfiles y Compresión Delta
Los objetos sueltos (loose objects) se almacenan como archivos individuales comprimidos con zlib dentro de `.git/objects/XX/YYYY...`. A medida que el repositorio crece, almacenar miles de archivos sueltos provoca el agotamiento de inodos del sistema de archivos y un deficiente rendimiento de E/S (I/O).

Git aborda esto utilizando **Packfiles** (`.pack`) e **Índices de Pack** (`.idx`):
- **Generación de Packfiles (`git gc` / `git pack-objects`):** Git escanea los objetos sueltos, agrupa objetos relacionados mediante algoritmos de ventana deslizante (sliding window) y realiza una compresión delta dirigida a nivel de bytes (almacenando diferencias de archivos en lugar de copias completas).
- **Indexación de Packs:** El archivo `.idx` proporciona una tabla de offsets de búsqueda binaria que mapea los hashes SHA directamente a offsets de bytes dentro del archivo `.pack`, permitiendo búsquedas de objetos $O(1)$.

---

### 1.4 Escalabilidad Empresarial, LFS y Arquitectura de Seguridad SCM
En grandes plataformas empresariales, los límites de escala se manifiestan al realizar el seguimiento de artefactos binarios (por ejemplo, modelos de machine learning, dumps de bases de datos) u operar repositorios de múltiples gigabytes:

- **Git LFS (Large File Storage):** Reemplaza blobs binarios grandes dentro de los árboles de commit de Git con archivos de puntero livianos (archivos de texto que contienen `version`, `oid sha256` y `size`). El contenido binario real se transfiere mediante HTTPS/S3 API a un almacenamiento de objetos externo durante los flujos de trabajo de checkout/push.
- **Aplicación de Políticas del Lado del Servidor (Server-Side Policy Enforcement):** Las plataformas SCM empresariales (GitLab, GitHub Enterprise, Gitea) aplican un cumplimiento estricto utilizando hooks de servidor de Git (`pre-receive`, `update`). Estos hooks analizan las operaciones de push entrantes para hacer cumplir commits firmados (GPG/SSH), prevención de escaneo de secretos, reglas de protección de ramas (branch protection rules) y estándares de commits semánticos antes de mutar los registros de referencia (`refs/heads/*`).

---

## 2. Comparaciones de Arquitectura Técnica y Análisis de Compromisos (Trade-Offs)

### Tabla 2.1: Arquitectura SCM Centralizado vs. SCM Distribuido

| Dimensión Arquitectónica | SCM Centralizado (Subversion / SVN) | SCM Distribuido (Git) |
| :--- | :--- | :--- |
| **Topología de Almacenamiento de Datos** | Servidor de base de datos relacional/archivos central único | DAG local completamente replicado en cada nodo cliente |
| **Operación de Commit** | Transacción de red síncrona al servidor central | Escritura atómica local al DAG `.git/objects/` local |
| **Mecánica de Ramificación (Branching)** | Copiar directorio dentro del árbol del repositorio central | Archivo de texto liviano que contiene un puntero SHA de 40 caracteres |
| **Latencia de Creación de Ramas** | $O(N)$ donde $N$ es la escala del árbol de directorios | Asignación $O(1)$ de 41 bytes (40 SHA + salto de línea) |
| **Capacidad Offline** | Inexistente; status, log y diff requieren conexión al servidor | Operación 100% offline excepto push/fetch |
| **Integridad del Historial** | ACL de base de datos del lado del servidor; historial del servidor mutable | DAG inmutable indexado por SHA; hashing criptográfico |
| **Eficiencia de Almacenamiento** | Almacenamiento delta centralizado | Objetos sueltos locales + packfiles delta con ventana deslizante |
| **Límite de Acceso Concurrente** | Alta contención de bloqueos de base de datos bajo carga pesada de CI | Cero contención de bloqueos locales; lectura/escritura local libre de bloqueos |

---

### Tabla 2.2: Estrategias de Integración de Ramas de Git (Merge vs. Rebase vs. Squash)

| Estrategia | Patrón de Comando | Estructura del DAG | Preservación del Historial | Complejidad de Rollback y Auditoría | Caso de Uso Adecuado en Producción |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Non-Fast-Forward Merge** | `git merge --no-ff feature` | Nodos de merge multipadre explícitos; grafo de doble línea | Preserva el historial cronológico real y el contexto del autor | Límites de merge claros; `git revert -m 1 <SHA>` simple | Finalización de rama de características (feature branch) a `main` / `release` |
| **Fast-Forward Merge** | `git merge --ff-only feature` | Lineal; la ref de destino avanza directamente a la punta de la característica | Elimina por completo el contexto del límite de la rama | Difícil identificar el límite de la característica para revertir en lote | Ramas temáticas (topic branches) de corta duración sin pérdida de contexto de CI |
| **Interactive Rebase** | `git rebase -i main` | Vuelve a aplicar commits sobre una nueva base; crea nuevos SHAs | Reescribe el historial en una secuencia lineal limpia | Más difícil depurar errores cronológicos en producción | Limpieza local antes de abrir Pull Requests |
| **Squash Merge** | `git merge --squash feature` | Combina los commits de la rama de características en 1 nuevo commit | Destruye el historial de commits intermedios de la característica | Reversión en un único commit limpio; mínimo ruido de commits | Despliegues de microservicios con estricto criterio de 1 commit por característica |

---

### Tabla 2.3: Topología de Repositorios Empresariales (Monorepo vs. Polyrepo)

| Métrica / Dimensión | Topología Monorepo | Topología Polyrepo |
| :--- | :--- | :--- |
| **Gestión de Dependencias** | Refactorización atómica entre servicios en un solo commit | Orquestación de PR en múltiples repositorios, versionado semántico |
| **Sobrecostes de Build en CI/CD** | Alto; requiere detección de cambios (Bazel, Nx, Turborepo) | Ejecución de pipeline aislada por repositorio de servicio |
| **Control de Acceso (RBAC)** | Complejo; requiere permisos basados en rutas (CODEOWNERS) | Simple; RBAC a nivel de repositorio y deploy keys |
| **Escala del Object Store de Git** | Crecimiento exponencial de objetos; requiere `scalar` / sparse-checkout | Huella de almacenamiento de objetos distribuida por equipo |
| **Requisitos de Herramientas** | Git LFS, sparse checkout, Sistemas de Archivos Virtuales (VFS) | CLI de Git estándar sin extensiones especializadas |

---

### Tabla 2.4: Mecanismos de Seguridad y Aplicación de Políticas en Git

| Nivel de Aplicación | Punto de Ejecución | Potencial de Omisión (Bypass) | Coste de Rendimiento | Caso de Uso Principal |
| :--- | :--- | :--- | :--- | :--- |
| **Client-Side Hooks** | `.git/hooks/pre-commit` | Alto (`git commit --no-verify`) | Se ejecuta en la CPU del desarrollador local | Linting, formateo, pruebas de cordura (sanity tests) locales |
| **Server Pre-Receive** | `/git-hooks/pre-receive` | Imposible (aplicado en el Server Root) | Bloquea la sesión de push `git-receive-pack` | Verificación GPG, escaneo de secretos, bloqueos de ramas |
| **Gate de Pipeline de CI/CD** | Runner/Worker externo | No se pueden omitir las reglas de protección de merge | Asíncrono; desacoplado de la latencia de push de git | Pruebas unitarias/integración, escaneo SAST/DAST |

---

## 3. Especificaciones Completas de Infraestructura y Manifiestos

### Manifiesto 3.1: Stack SCM Empresarial en Alta Disponibilidad con Git LFS (Espec de Producción para Kubernetes)

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: scm-system
  labels:
    tier: infrastructure
    app.kubernetes.io/name: git-server
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: gitea-config
  namespace: scm-system
data:
  app.ini: |
    APP_NAME = Enterprise Production SCM Engine
    RUN_MODE = prod
    RUN_USER = git

    [repository]
    ROOT = /data/git/repositories
    DEFAULT_BRANCH = main
    ENABLE_PUSH_CREATE_USER = false
    ENABLE_PUSH_CREATE_ORG = false
    MAX_CREATION_LIMIT = 50
    DEFAULT_PRIVATE = private

    [server]
    PROTOCOL = http
    DOMAIN = git.enterprise.internal
    HTTP_PORT = 3000
    ROOT_URL = https://git.enterprise.internal/
    DISABLE_SSH = false
    SSH_PORT = 2222
    SSH_LISTEN_PORT = 2222
    LFS_START_SERVER = true
    LFS_JWT_SECRET = c7a9e3f1b4d8a2c6e9f1a3b5c7d9e1f3

    [lfs]
    STORAGE_TYPE = minio
    PATH = /data/git/lfs
    MINIO_ENDPOINT = minio.storage.svc.cluster.local:9000
    MINIO_ACCESS_KEY_ID = scm-lfs-admin
    MINIO_SECRET_ACCESS_KEY = SuperSecretEnterpriseLFSKey2026!
    MINIO_BUCKET = git-lfs-objects
    MINIO_LOCATION = us-east-1
    MINIO_USE_SSL = false

    [database]
    DB_TYPE = postgres
    HOST = postgres-ha.database.svc.cluster.local:5432
    NAME = gitea_db
    USER = gitea_user
    PASSWD = SecurePostgresPassword2026!
    SSL_MODE = verify-full

    [security]
    INSTALL_LOCK = true
    SECRET_KEY = e1f3a5b7c9d1e3f5a7b9c1d3e5f7a9b1
    REVERSE_PROXY_TRUSTED_PROXIES = 10.244.0.0/16
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: gitea-scm
  namespace: scm-system
  labels:
    app.kubernetes.io/name: gitea-scm
spec:
  replicas: 1
  serviceName: gitea-scm-headless
  selector:
    matchLabels:
      app.kubernetes.io/name: gitea-scm
  template:
    metadata:
      labels:
        app.kubernetes.io/name: gitea-scm
    spec:
      containers:
        - name: gitea
          image: gitea/gitea:1.21.11
          imagePullPolicy: IfNotPresent
          env:
            - name: USER_UID
              value: "1000"
            - name: USER_GID
              value: "1000"
          ports:
            - name: http
              containerPort: 3000
              protocol: TCP
            - name: ssh
              containerPort: 2222
              protocol: TCP
          volumeMounts:
            - name: gitea-data
              mountPath: /data
            - name: config-volume
              mountPath: /data/gitea/conf/app.ini
              subPath: app.ini
          resources:
            requests:
              cpu: "2"
              memory: 4Gi
            limits:
              cpu: "4"
              memory: 8Gi
          livenessProbe:
            httpGet:
              path: /api/v1/healthz
              port: http
            initialDelaySeconds: 30
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /api/v1/healthz
              port: http
            initialDelaySeconds: 15
            periodSeconds: 5
      volumes:
        - name: config-volume
          configMap:
            name: gitea-config
  volumeClaimTemplates:
    - metadata:
        name: gitea-data
      spec:
        accessModes: [ "ReadWriteOnce" ]
        storageClassName: "gp3-encrypted"
        resources:
          requests:
            storage: 200Gi
---
apiVersion: v1
kind: Service
metadata:
  name: gitea-scm-service
  namespace: scm-system
spec:
  type: ClusterIP
  ports:
    - name: http
      port: 80
      targetPort: 3000
    - name: ssh
      port: 22
      targetPort: 2222
  selector:
    app.kubernetes.io/name: gitea-scm
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: gitea-scm-ingress
  namespace: scm-system
  annotations:
    kubernetes.io/ingress.class: nginx
    nginx.ingress.kubernetes.io/proxy-body-size: "512m"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  tls:
    - hosts:
        - git.enterprise.internal
      secretName: git-tls-cert
  rules:
    - host: git.enterprise.internal
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: gitea-scm-service
                port:
                  number: 80
```

---

### Manifiesto 3.2: Script de Hook Pre-Receive para Servidor Git Empresarial (`/git-hooks/pre-receive`)

```bash
#!/usr/bin/env bash
# ==============================================================================
# Production Server-Side Pre-Receive Security & Compliance Hook
# Enforces:
# 1. Blocked Secret Detection (AWS Keys, Private Keys, Generic Tokens)
# 2. Branch Protection (Direct Pushes to 'main' or 'release-*' Forbidden)
# 3. Conventional Commit Message Syntax Compliance
# ==============================================================================

set -euo pipefail

ZERO_REG="0000000000000000000000000000000000000000"
REGEX_AWS_KEY="AKIA[0-9A-Z]{16}"
REGEX_PRIVATE_KEY="-----BEGIN (RSA|OPENSSH|EC|PGP) PRIVATE KEY-----"
REGEX_CONVENTIONAL_COMMIT="^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([a-z0-9_-]+\))?: .+"

exit_code=0

while read -r oldrev newrev refname; do
    # 1. Enforce Protected Branch Rules
    branch_name="${refname#refs/heads/}"
    if [[ "${branch_name}" == "main" || "${branch_name}" =~ ^release-.* ]]; then
        # Allow deletion of branch if explicitly permitted, otherwise block direct push
        if [[ "${newrev}" != "${ZERO_REG}" ]]; then
            # Check if this push is an initial creation or bypass attempt
            echo "[ERROR] [SCM-POLICY] Direct push to protected branch '${branch_name}' is forbidden." >&2
            echo "[ERROR] [SCM-POLICY] You must submit changes via a Pull/Merge Request." >&2
            exit_code=1
            continue
        fi
    fi

    # Skip commit inspection if branch is being deleted
    if [[ "${newrev}" == "${ZERO_REG}" ]]; then
        continue
    fi

    # Determine revision range for commit evaluation
    if [[ "${oldrev}" == "${ZERO_REG}" ]]; then
        # New branch being pushed: check commits relative to main
        commit_range="$(git rev-parse --not main | git rev-list --stdin "${newrev}")"
    else
        commit_range="$(git rev-list "${oldrev}..${newrev}")"
    fi

    # 2. Iterate Over Incoming Commits
    for commit in ${commit_range}; do
        # Extract Commit Message
        commit_msg="$(git log --format=%B -n 1 "${commit}")"
        commit_subject="$(echo "${commit_msg}" | head -n 1)"

        # Validate Conventional Commits Standard
        if [[ ! "${commit_subject}" =~ ${REGEX_CONVENTIONAL_COMMIT} ]]; then
            echo "[ERROR] [SCM-POLICY] Invalid commit message structure in commit ${commit:0:8}." >&2
            echo "[ERROR] [SCM-POLICY] Subject: '${commit_subject}'" >&2
            echo "[ERROR] [SCM-POLICY] Commit message must follow format: type(scope): description" >&2
            exit_code=1
        fi

        # Extract File Changes & Check for Secrets
        changed_files="$(git diff-tree --no-commit-id --name-only -r "${commit}")"
        for file in ${changed_files}; do
            # Skip deleted files inside commit
            if ! git cat-file -e "${commit}:${file}" 2>/dev/null; then
                continue
            fi

            file_content="$(git cat-file -p "${commit}:${file}")"

            # Secret Scan: AWS Access Key ID
            if echo "${file_content}" | grep -E -q "${REGEX_AWS_KEY}"; then
                echo "[FATAL] [SCM-SECURITY] Hardcoded AWS Key detected in commit ${commit:0:8}, file: ${file}" >&2
                exit_code=1
            fi

            # Secret Scan: Private Key Material
            if echo "${file_content}" | grep -E -q "${REGEX_PRIVATE_KEY}"; then
                echo "[FATAL] [SCM-SECURITY] Unencrypted Private Key material detected in commit ${commit:0:8}, file: ${file}" >&2
                exit_code=1
            fi
        done
    done
done

if [[ ${exit_code} -ne 0 ]]; then
    echo "[REJECTED] Push policy violation detected. Transaction aborted." >&2
    exit 1
fi

exit 0
```

---

### Manifiesto 3.3: Reglas de Configuración de Repositorio en Producción (`.gitignore` y `.gitattributes`)

#### Archivo: `.gitignore`
```gitignore
# Operating System Artifacts
.DS_Store
Thumbs.db
*.swp
*.swo

# Infrastructure & Local State Secrets
*.tfstate
*.tfstate.backup
.terraform/
*.pem
*.key
*.pfx
.env
.env.local

# Language Build Output Directories
bin/
obj/
dist/
build/
target/
node_modules/
*.so
*.dylib
*.dll

# IDE & Tooling Directories
.idea/
.vscode/
*.suo
*.user

# Log Files & Crash Dumps
*.log
npm-debug.log*
yarn-debug.log*
yarn-error.log*
core.[0-9]*
```

#### Archivo: `.gitattributes`
```gitattributes
# Set Default Text Normalization (LF in Repo)
* text=auto eol=lf

# Force Explicit Line Endings for Shell Scripts & Windows Batches
*.sh text eol=lf
*.bat text eol=crlf
*.cmd text eol=crlf

# Git LFS Binary Asset Mapping
*.png filter=lfs diff=lfs merge=lfs -text
*.jpg filter=lfs diff=lfs merge=lfs -text
*.mp4 filter=lfs diff=lfs merge=lfs -text
*.iso filter=lfs diff=lfs merge=lfs -text
*.tar.gz filter=lfs diff=lfs merge=lfs -text
*.onnx filter=lfs diff=lfs merge=lfs -text
*.tflite filter=lfs diff=lfs merge=lfs -text

# Linguist & Custom Merge Driver Overrides
docs/* linguist-documentation
vendor/* linguist-vendored
package-lock.json merge=binary
```

---

## 4. Ejecución Real en CLI, Plumbing Interno y Salida de Terminal

### 4.1 Mecánica de Objetos de Git de Bajo Nivel (Creación Manual de un Commit mediante Plumbing)
Esta guía práctica demuestra la mecánica subyacente del almacenamiento de objetos de Git construyendo manualmente un objeto Blob, Tree y Commit utilizando comandos de plumbing de Git, omitiendo `git add` y `git commit`.

```bash
$ mkdir /tmp/git-plumbing-lab && cd /tmp/git-plumbing-lab
$ git init
Initialized empty Git repository in /tmp/git-plumbing-lab/.git/

$ # Step 1: Create a Blob object directly in .git/objects
$ echo "package main; func main() { println(\"SRE Core v1\") }" | git hash-object -w --stdin
e2380d381ae516c141fa168a9b6c0032b4bfa254

$ # Step 2: Verify the object type and content in the database
$ git cat-file -t e2380d381ae516c141fa168a9b6c0032b4bfa254
blob

$ git cat-file -p e2380d381ae516c141fa168a9b6c0032b4bfa254
package main; func main() { println("SRE Core v1") }

$ # Step 3: Write the Blob into the Staging Index with permissions (100644)
$ git update-index --add --cacheinfo 100644 e2380d381ae516c141fa168a9b6c0032b4bfa254 main.go

$ # Step 4: Write the Staging Index into a Tree Object
$ git write-tree
9b8e217d848149e9e1c142c16182ef89fb6c08bc

$ git cat-file -p 9b8e217d848149e9e1c142c16182ef89fb6c08bc
100644 blob e2380d381ae516c141fa168a9b6c0032b4bfa254	main.go

$ # Step 5: Construct a Commit Object referencing the Tree SHA
$ COMMIT_SHA=$(echo "feat(core): initial manual plumbing commit" | git commit-tree 9b8e217d848149e9e1c142c16182ef89fb6c08bc)
$ echo ${COMMIT_SHA}
a5c89f1d02e49c81b2a731d1029e84b3f11a8c9e

$ git cat-file -p ${COMMIT_SHA}
tree 9b8e217d848149e9e1c142c16182ef89fb6c08bc
author SRE Admin <sre@company.internal> 1775536920 -0400
committer SRE Admin <sre@company.internal> 1775536920 -0400

feat(core): initial manual plumbing commit

$ # Step 6: Update the HEAD reference pointer to the new Commit SHA
$ git update-ref refs/heads/main ${COMMIT_SHA}
$ git log -n 1
commit a5c89f1d02e49c81b2a731d1029e84b3f11a8c9e (HEAD -> main)
Author: SRE Admin <sre@company.internal>
Date:   Tue Aug 7 04:42:00 2026 -0400

    feat(core): initial manual plumbing commit
```

---

### 4.2 Aislamiento Avanzado de Worktrees (Ingeniería Multirrama)
`git worktree` permite vincular múltiples árboles de trabajo (working trees) a una sola base de datos de objetos `.git` compartida, eliminando el reclonado local completo al cambiar entre ramas de hotfix y ramas de características (feature branches) de larga duración.

```bash
$ cd /tmp/git-plumbing-lab
$ git branch feature/auth
$ git branch hotfix/vuln-patch

$ # Create a dedicated workspace directory for hotfix development
$ git worktree add ../hotfix-workspace hotfix/vuln-patch
Preparing worktree (checking out 'hotfix/vuln-patch')
HEAD is now at a5c89f1 feat(core): initial manual plumbing commit

$ git worktree list
/tmp/git-plumbing-lab   a5c89f1 [main]
/tmp/hotfix-workspace   a5c89f1 [hotfix/vuln-patch]

$ # Remove worktree after work completion
$ git worktree remove ../hotfix-workspace
$ git worktree list
/tmp/git-plumbing-lab   a5c89f1 [main]
```

---

### 4.3 Localización Automatizada de Fallas (`git bisect`)
`git bisect` utiliza un algoritmo de búsqueda binaria a lo largo del historial de commits para aislar el commit exacto que introdujo una regresión de software.

```bash
$ cd /tmp/git-plumbing-lab
$ # Initiate bisect session
$ git bisect start
$ git bisect bad HEAD                                  # Mark current HEAD as broken
$ git bisect good a5c89f1d02e49c81b2a731d1029e84b3f11a # Mark known good historical SHA
Bisecting: 12 revisions left to test after this (roughly 4 steps)
[3f8a9b2c1d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a] feat(api): update handler payload

$ # Run automated script test runner over bisect range
$ git bisect run go test -run TestProductionRegression ./...
running go test -run TestProductionRegression ./...
...
3f8a9b2c1d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a is the first bad commit
commit 3f8a9b2c1d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a
Author: Dev <dev@company.com>
Date:   Mon Aug 6 14:22:10 2026 -0400

    feat(api): update handler payload

Bisect run success.
$ git bisect reset
Previous HEAD position was 3f8a9b2 feat(api): update handler payload
HEAD is now at a5c89f1 feat(core): initial manual plumbing commit
```

---

## 5. Guía de Diagnóstico, Recuperación de Fallas y Mantenimiento SRE

### Matriz de Diagnóstico: Escenarios de Falla en Producción y Rutas de Solución de Problemas

```
                             Production Failure Symptoms Detected
                                              |
      +---------------------------------------+---------------------------------------+
      |                                       |                                       |
      v                                       v                                       v
[ Fatal: Corrupt Object ]            [ Head Detached / Lost ]              [ Repository Bloat ]
  - Object SHA mismatched              - Untracked local commits             - Push rejected (>100MB)
  - Loose object zero bytes            - Accidental rebase/reset             - Object store > 10GB
      |                                       |                                       |
      v                                       v                                       v
Run `git fsck --full`               Run `git reflog`                       Run `git-filter-repo`
Check `.git/objects/pack`           Locate last valid SHA                  Remove heavy binary SHAs
Restore from remote mirror          Run `git branch recover <SHA>`         Run `git gc --prune=now`
```

---

### Escenario de Falla 5.1: Recuperación de Corrupción en la Base de Datos de Objetos
**Síntoma:** `git log` o `git checkout` falla con `error: inflate: data stream error (incorrect header check)` o `fatal: loose object ... is corrupt`.

#### Secuencia de Diagnóstico:
```bash
$ # Step 1: Perform full strict integrity check across all loose and packed objects
$ git fsck --full --strict
error: sha1 mismatch 6b8b4567000e47c3ab37b65c362ba92c8d8d1cfc
error: 6b8b4567000e47c3ab37b65c362ba92c8d8d1cfc: object corrupt or missing
dangling blob 9f8a7c6b5a4e3d2c1b0a9f8e7d6c5b4a3f2e1d0c

$ # Step 2: Locate corrupt loose object file in filesystem
$ find .git/objects/ -type f -empty
.git/objects/6b/8b4567000e47c3ab37b65c362ba92c8d8d1cfc

$ # Step 3: Remove zero-byte / corrupt object
$ rm -f .git/objects/6b/8b4567000e47c3ab37b65c362ba92c8d8d1cfc

$ # Step 4: Fetch missing object directly from upstream authoritative mirror
$ git fetch origin --force
remote: Enumerating objects: 1, done.
remote: Counting objects: 100% (1/1), done.
Unpacking objects: 100% (1/1), 240 bytes | 240.00 KiB/s, done.
From https://git.enterprise.internal/scm/repo
 * [new branch]      main       -> origin/main

$ # Step 5: Verify DAG consistency post-recovery
$ git fsck --full
Notice: Unreachable dangling blob 9f8a7c6b5a4e3d2c1b0a9f8e7d6c5b4a3f2e1d0c
Checking object directories: 100% (256/256), done.
Checking objects: 100% (1420/1420), done.
```

---

### Escenario de Falla 5.2: Recuperación de Commits Perdidos (Análisis de Reflog)
**Síntoma:** Un desarrollador ejecuta accidentalmente `git reset --hard HEAD~5` o `git rebase`, perdiendo commits críticos de características no integradas.

#### Secuencia de Diagnóstico:
```bash
$ # Step 1: Inspect execution reflog to identify state prior to reset
$ git reflog --date=iso
a5c89f1 HEAD@{2026-08-07 04:20:00 -0400}: reset: moving to HEAD~5
e9f8a7b HEAD@{2026-08-07 04:15:12 -0400}: commit: feat(auth): finalize OAuth2 implementation
8c7b6a5 HEAD@{2026-08-07 04:02:00 -0400}: commit: feat(auth): add PKCE generator

$ # Step 2: Create a recovery branch directly targeting lost commit SHA (e9f8a7b)
$ git checkout -b recovery/lost-oauth-feature e9f8a7b
Switched to a new branch 'recovery/lost-oauth-feature'
HEAD is now at e9f8a7b feat(auth): finalize OAuth2 implementation

$ # Step 3: Verify restored state
$ git log -n 2 --oneline
e9f8a7b (HEAD -> recovery/lost-oauth-feature) feat(auth): finalize OAuth2 implementation
8c7b6a5 feat(auth): add PKCE generator
```

---

### Escenario de Falla 5.3: Reducción de Tamaño del Repositorio (Debloating) (Purga de Archivos Binarios Grandes Accidentalmente Añadidos)
**Síntoma:** Se hizo commit de un archivo zip de 500 MB hace 100 commits. El archivo fue eliminado en un commit reciente, pero `.git/objects/pack` sigue abultado en >500 MB porque el objeto continúa siendo referenciado en los árboles de commits históricos.

#### Secuencia de Remediación:
```bash
$ # Step 1: Identify heavy objects inside packfiles
$ git verify-pack -v .git/objects/pack/pack-*.idx | sort -k3 -n -r | head -n 5
c1f8a9e2d3b4a5c6d7e8f9a0b1c2d3e4f5a6b7c8 blob 524288000 384021000 120490

$ # Step 2: Find file paths associated with the identified heavy SHA
$ git rev-list --objects --all | grep c1f8a9e2d3b4a5c6d7e8f9a0b1c2d3e4f5a6b7c8
c1f8a9e2d3b4a5c6d7e8f9a0b1c2d3e4f5a6b7c8 storage/db_dump.tar.gz

$ # Step 3: Purge file completely from all historical DAG commit trees using git-filter-repo
$ git-filter-repo --invert-paths --path storage/db_dump.tar.gz
Parsed 1420 commits
New history written in 3.12 seconds.

$ # Step 4: Expire reflogs, prune loose unreferenced objects, and rebuild packfiles
$ git reflog expire --expire=now --all
$ git gc --prune=now --aggressive
Enumerating objects: 910, done.
Counting objects: 100% (910/910), done.
Delta compression using up to 8 threads
Compressing objects: 100% (420/420), done.
Writing objects: 100% (910/910), done.
Total 910 (delta 490), reused 0 (delta 0), pack-reused 0

$ # Step 5: Force push sanitized history to remote authority
$ git push origin --force --all
```

---

## 6. Referencias

- **Linux Professional Institute (LPI) DevOps Tools Engineer Objectives:**  
  https://www.lpi.org/our-certifications/devops-tools-engineer-overview/
- **LPI Wiki — Topic 701.3 Source Code Management Details:**  
  https://wiki.lpi.org/wiki/DevOps_Tools_Engineer_Objectives_V1.0
- **Git Official Internal Documentation (Pro Git - Git Internals):**  
  https://git-scm.com/book/en/v2/Git-Internals-Plumbing-and-Porcelain
- **Git Mechanics: Packfiles and Index Files Standard Specification:**  
  https://git-scm.com/docs/pack-format
- **Git Large File Storage (LFS) Architecture Specification:**  
  https://git-lfs.com/
- **CNCF GitOps Principles & OpenGitOps Standard:**  
  https://opengitops.dev/