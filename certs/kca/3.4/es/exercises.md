# Ejercicios — 3.4 Instalación de la CLI de Kyverno

> **Alcance.** Estos ejercicios guiados cubren la *instalación* y la *validación* de la CLI de Kyverno (`kyverno` / `kubectl-kyverno`) a través de los cuatro canales soportados —Krew, binario de release directo, Homebrew y la imagen de contenedor—, además de la compatibilidad de versiones y la autoinspección de la CLI. La CLI es la herramienta que usás para probar, aplicar y hacer lint de policies **fuera de un clúster** (desarrollo local, gates de CI/CD), así que instalarla y versionarla correctamente es fundamental para cada tema posterior.
>
> Referencias oficiales usadas a lo largo del documento:
> - Guía de instalación de la CLI de Kyverno — https://kyverno.io/docs/kyverno-cli/install/
> - Uso de la CLI de Kyverno — https://kyverno.io/docs/kyverno-cli/usage/
> - Releases de GitHub (binarios + checksums) — https://github.com/kyverno/kyverno/releases
> - Gestor de plugins Krew — https://krew.sigs.k8s.io/
> - Imagen de contenedor de la CLI de Kyverno — https://github.com/kyverno/kyverno/pkgs/container/kyverno-cli

---

## Ejercicio 1 — Instalar vía Krew (la ruta recomendada)

Krew es el gestor oficial de plugins de `kubectl`. Instalar la CLI de Kyverno a través de Krew la registra como el subcomando `kubectl kyverno`, de modo que hereda automáticamente tu kubeconfig y el completado del shell.

1. Confirmá que `kubectl` está en tu `PATH` y registrá su versión:

   ```bash
   kubectl version --client -o yaml | grep gitVersion
   ```

   Esperado (los valores varían):

   ```yaml
     gitVersion: v1.30.2
   ```

2. Confirmá que Krew en sí está instalado (es un prerrequisito, **no** viene incluido con `kubectl`):

   ```bash
   kubectl krew version
   ```

   Esperado:

   ```
   OPTION            VALUE
   GitTag            v0.4.4
   GitCommit         343e657
   IndexURI          https://github.com/kubernetes-sigs/krew-index.git
   BasePath          /home/student/.krew
   IndexPath         /home/student/.krew/index/default
   InstallPath       /home/student/.krew/store
   BinPath           /home/student/.krew/bin
   DetectedPlatform  linux/amd64
   ```

   Si esto falla con `unknown command "krew"`, instalá Krew primero siguiendo https://krew.sigs.k8s.io/docs/user-guide/setup/install/ y asegurate de que `${KREW_ROOT:-$HOME/.krew}/bin` esté antepuesto a tu `PATH`.

3. Actualizá el índice de plugins e instalá el plugin de Kyverno:

   ```bash
   kubectl krew update
   kubectl krew install kyverno
   ```

   Cola esperada de la salida:

   ```
   Installing plugin: kyverno
   Installed plugin: kyverno
   \
    | Use this plugin:
    | 	kubectl kyverno
    | Documentation:
    | 	https://github.com/kyverno/kyverno
   /
   WARNING: You installed plugin "kyverno" from the krew-index plugin repository.
      These plugins are not audited for security by the Krew maintainers.
   ```

4. Invocá el plugin recién instalado:

   ```bash
   kubectl kyverno version
   ```

   Esperado:

   ```
   Version: 1.13.4
   Time: 2025-04-08T12:14:03Z
   Git commit ID: 9a1b2c3d4e5f60718293a4b5c6d7e8f901234567
   ```

> **Preguntas**
> 1. Después de una instalación con Krew, ¿por qué el comando es `kubectl kyverno` y no `kyverno`? ¿Qué convención de nombres hace que esto funcione?
> 2. `kubectl krew version` falló en la laptop de un colega aunque `kubectl` funciona perfectamente. ¿Cuál es la causa más probable, y qué único hecho revela esto sobre la relación de Krew con `kubectl`?
> 3. La instalación imprimió un `WARNING` de seguridad. En una oración, ¿qué te está diciendo realmente, y bloquea la instalación?

---

## Ejercicio 2 — Instalar desde un binario de release con verificación de checksum

Krew es cómodo, pero los runners de CI y los entornos air-gapped a menudo necesitan un binario fijado y verificable. Acá instalás una versión específica directamente desde el release de GitHub y **probás su integridad** antes de confiar en él.

1. Elegí una versión explícita y detectá tu plataforma. Fijá la versión — nunca dependas de "latest" en un pipeline:

   ```bash
   KV_VER="v1.13.4"
   OS=$(uname | tr '[:upper:]' '[:lower:]')          # linux | darwin
   ARCH=$(uname -m | sed 's/x86_64/x86_64/;s/aarch64/arm64/')   # x86_64 | arm64
   echo "$OS/$ARCH"
   ```

   Esperado:

   ```
   linux/x86_64
   ```

2. Descargá el archivo comprimido **y** el archivo de checksums de ese release:

   ```bash
   BASE="https://github.com/kyverno/kyverno/releases/download/${KV_VER}"
   curl -sSLO "${BASE}/kyverno-cli_${KV_VER}_${OS}_${ARCH}.tar.gz"
   curl -sSLO "${BASE}/checksums.txt"
   ls -1
   ```

   Esperado:

   ```
   checksums.txt
   kyverno-cli_v1.13.4_linux_x86_64.tar.gz
   ```

3. Verificá el SHA-256 del archivo contra el checksum publicado **antes** de extraer nada:

   ```bash
   sha256sum --ignore-missing -c checksums.txt
   ```

   Esperado:

   ```
   kyverno-cli_v1.13.4_linux_x86_64.tar.gz: OK
   ```

   Si esto imprime `FAILED`, **pará** — no extraigas ni ejecutes el binario.

4. Extraé e instalá en tu `PATH`:

   ```bash
   tar -xvf "kyverno-cli_${KV_VER}_${OS}_${ARCH}.tar.gz"
   sudo install -m 0755 kyverno /usr/local/bin/kyverno
   ```

   Esperado:

   ```
   LICENSE
   kyverno
   ```

5. Confirmá que el binario corre y reporta la versión que fijaste:

   ```bash
   kyverno version
   ```

   Esperado:

   ```
   Version: 1.13.4
   Time: 2025-04-08T12:14:03Z
   Git commit ID: 9a1b2c3d4e5f60718293a4b5c6d7e8f901234567
   ```

> **Preguntas**
> 1. El paso 3 usa `sha256sum -c` **antes** de que el paso 4 extraiga el archivo. ¿Por qué el orden es relevante para la seguridad — qué clase de ataque previene verificar *antes* de extraer que verificar *después* no prevendría?
> 2. ¿Qué logra la flag `--ignore-missing` dado que `checksums.txt` lista los assets de cada OS/arch del release?
> 3. Cuando se instala de esta manera el binario se llama `kyverno`, pero la instalación con Krew del Ejercicio 1 te dio `kubectl kyverno`. ¿Son el mismo ejecutable en cuanto a contenido? ¿Cuál es la única diferencia significativa desde la perspectiva del shell?

---

## Ejercicio 3 — Instalar vía Homebrew

En macOS y Linux, Homebrew te da una instalación gestionada por paquetes con actualizaciones automáticas.

1. Confirmá que Homebrew está presente:

   ```bash
   brew --version
   ```

   Esperado:

   ```
   Homebrew 4.3.9
   ```

2. Instalá la fórmula de la CLI de Kyverno:

   ```bash
   brew install kyverno
   ```

   Cola esperada:

   ```
   ==> Fetching kyverno
   ==> Pouring kyverno--1.13.4.arm64_sonoma.bottle.tar.gz
   🍺  /opt/homebrew/Cellar/kyverno/1.13.4: 6 files, 61.2MB
   ```

3. Verificá y anotá dónde ubicó Homebrew el binario:

   ```bash
   kyverno version
   which kyverno
   ```

   Esperado:

   ```
   Version: 1.13.4
   Time: 2025-04-08T12:14:03Z
   Git commit ID: 9a1b2c3d4e5f60718293a4b5c6d7e8f901234567
   /opt/homebrew/bin/kyverno
   ```

4. Más adelante, actualizá a un release más nuevo sin tocar tu `PATH`:

   ```bash
   brew upgrade kyverno
   ```

> **Preguntas**
> 1. Tenés `kyverno` de Homebrew en `/opt/homebrew/bin` *y* uno instalado manualmente en `/usr/local/bin` (del Ejercicio 2). ¿Cuál se ejecuta cuando escribís `kyverno`, y qué lo determina?
> 2. Dá una razón operativa por la que aún podrías preferir el método del binario fijado del Ejercicio 2 sobre `brew install` dentro de un pipeline de CI.

---

## Ejercicio 4 — Ejecutar la CLI como una imagen de contenedor (sin instalación local)

Para jobs de CI efímeros a menudo querés cero huella en el runner. La CLI se distribuye como una imagen OCI, así que podés ejecutarla de forma descartable.

1. Descargá y ejecutá un tag de imagen fijado, pidiendo la versión:

   ```bash
   docker run --rm ghcr.io/kyverno/kyverno-cli:v1.13.4 version
   ```

   Esperado:

   ```
   Version: 1.13.4
   Time: 2025-04-08T12:14:03Z
   Git commit ID: 9a1b2c3d4e5f60718293a4b5c6d7e8f901234567
   ```

2. Para operar sobre archivos locales (por ejemplo, hacer lint de una policy), montá tu directorio de trabajo dentro del contenedor. El entrypoint de la imagen es el binario `kyverno`, así que pasás los subcomandos directamente:

   ```bash
   docker run --rm -v "$(pwd):/work" -w /work \
     ghcr.io/kyverno/kyverno-cli:v1.13.4 \
     apply require-labels.yaml --resource deploy.yaml
   ```

   Esperado (forma de la salida — los detalles dependen de tus archivos):

   ```
   Applying 1 policy rule(s) to 1 resource(s)...

   pass: 1, fail: 0, warn: 0, error: 0, skip: 0
   ```

> **Preguntas**
> 1. En el paso 2, ¿por qué el bind mount `-v "$(pwd):/work" -w /work` es obligatorio? ¿Qué vería `kyverno apply require-labels.yaml ...` dentro del contenedor sin él?
> 2. El tag de la imagen es `:v1.13.4`, no `:latest`. Enunciá el argumento de reproducibilidad para fijar el tag en un job de CI.
> 3. El entrypoint del contenedor ya es `kyverno`, así que escribiste `... kyverno-cli:v1.13.4 version` (sin `kyverno` antes de `version`). ¿Qué pasaría si *sí* escribieras `... kyverno-cli:v1.13.4 kyverno version`?

---

## Ejercicio 5 — Validar la instalación y hacer coincidir las versiones con el clúster

Instalar el binario es solo la mitad del trabajo; un operador a nivel KCA confirma las capacidades de la CLI y su **compatibilidad** con el controlador de Kyverno que corre en el clúster.

1. Enumerá los subcomandos de nivel superior que expone la CLI:

   ```bash
   kyverno --help
   ```

   Esperado (abreviado — el conjunto de comandos es lo importante):

   ```
   Kubernetes Native Policy Management.

   Usage:
     kyverno [command]

   Available Commands:
     apply       Applies policies on resources.
     create      Provides a command-line interface to help with the creation of various Kyverno resources.
     docs        Generates reference documentation.
     fix         Provides a command-line interface to help with Kyverno resources.
     jp          Provides a command-line interface to JMESPath, enhanced with Kyverno specific custom functions.
     migrate     Migrates Kyverno resources from v1 to v2.
     oci         Pulls/pushes images that include policie(s) from/to an OCI registry.
     test        Run tests from a local filesystem.
     version     Shows current version of kyverno.

   Flags:
     -h, --help   help for kyverno
   ```

2. Registrá la versión de la CLI de una forma que un script pueda parsear:

   ```bash
   kyverno version | awk '/^Version:/ {print $2}'
   ```

   Esperado:

   ```
   1.13.4
   ```

3. Comparala con el controlador de Kyverno desplegado en tu clúster (la versión de la CLI debería ser **compatible con**, y típicamente coincidir en el minor con, el release en el clúster):

   ```bash
   kubectl -n kyverno get deploy kyverno-admission-controller \
     -o jsonpath='{.spec.template.spec.containers[0].image}'
   echo
   ```

   Esperado:

   ```
   ghcr.io/kyverno/kyverno:v1.13.4
   ```

4. Verificá que una policy que la CLI acepta localmente sea una que la versión del clúster también entienda, comparando los dos minor versions:

   ```bash
   CLI_MINOR=$(kyverno version | awk '/^Version:/ {print $2}' | cut -d. -f1,2)
   CLUSTER_MINOR=$(kubectl -n kyverno get deploy kyverno-admission-controller \
     -o jsonpath='{.spec.template.spec.containers[0].image}' \
     | sed 's/.*:v//' | cut -d. -f1,2)
   echo "CLI: ${CLI_MINOR}  Cluster: ${CLUSTER_MINOR}"
   [ "$CLI_MINOR" = "$CLUSTER_MINOR" ] && echo "MATCH" || echo "MISMATCH — review policy API compatibility"
   ```

   Esperado:

   ```
   CLI: 1.13  Cluster: 1.13
   MATCH
   ```

> **Preguntas**
> 1. ¿Qué único subcomando del paso 1 usarías en un gate de CI para ejecutar una suite de aserciones de policy desde un directorio local *sin ningún clúster*? ¿Cuál aplica policies a recursos y reporta pass/fail?
> 2. ¿Por qué la guía de KCA enfatiza hacer coincidir la versión **minor** de la CLI con el controlador en el clúster? Dá una falla concreta que un desajuste puede causar al escribir policies.
> 3. En el paso 3 leés la imagen desde el Deployment `kyverno-admission-controller`. Nombrá una razón por la que leer el *tag de la imagen en ejecución* es más confiable que asumir la versión a partir de un `values.yaml` de Helm o de la versión del chart.

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1
1. **Krew instala el plugin como un binario llamado `kubectl-kyverno`.** `kubectl` descubre cualquier ejecutable en el `PATH` cuyo nombre comience con `kubectl-` y expone el sufijo como un subcomando (`kubectl-kyverno` → `kubectl kyverno`). Este es el mecanismo estándar de plugins de `kubectl`, de modo que la CLI hereda automáticamente tu kubeconfig/contexto actual.
2. Krew **no es parte de `kubectl`** — es un plugin de `kubectl` instalado por separado (llamado a su vez `kubectl-krew`). Que `kubectl` funcione no prueba nada sobre Krew. El colega o nunca instaló Krew o su directorio `bin` (`$HOME/.krew/bin`) no está en el `PATH`. La revelación: Krew es una *dependencia que instalás primero*, no una funcionalidad incluida.
3. La advertencia indica que los plugins en el krew-index son **contribuidos por la comunidad y no auditados en seguridad por los mantenedores de Krew** — estás confiando en quien publica el plugin (acá, el proyecto Kyverno). Es informativa y **no bloquea** la instalación; el plugin se instala de todos modos.

### Ejercicio 2
1. Verificar el checksum **antes de la extracción** garantiza que nunca desempaquetás un archivo manipulado/corrupto. `tar -x` sobre un archivo malicioso puede ser peligroso en sí mismo (entradas de path-traversal que escriben fuera del directorio objetivo, trucos con symlinks) — y por supuesto no debés ejecutar un binario que no autenticaste. Verificar *después* de la extracción significa que el archivo no confiable ya fue procesado. Verificar-luego-extraer mantiene los bytes no confiables inertes hasta probar que están intactos.
2. `checksums.txt` contiene una línea por asset del release (cada OS/arch). `--ignore-missing` le dice a `sha256sum -c` que verifique **solo los archivos presentes en el directorio actual** y omita los muchos archivos listados que no descargaste, en lugar de reportarlos a todos como `FAILED`/faltantes. Aun así obtenés un `OK`/`FAILED` autoritativo para el único archivo que tenés.
3. Byte por byte es la **misma CLI de Kyverno compilada**. La única diferencia es la invocación y el descubrimiento: llamado `kyverno` en el `PATH` es un comando autónomo; llamado `kubectl-kyverno` (como lo instala Krew) `kubectl` lo hace aparecer como el subcomando `kubectl kyverno`. Misma funcionalidad, distinto punto de entrada.

### Ejercicio 3
1. Gana el directorio que aparezca **primero en el `PATH`**. Si `/opt/homebrew/bin` precede a `/usr/local/bin`, corre el build de Homebrew; de lo contrario, el manual. Resolvé la ambigüedad con `which -a kyverno` (lista todas las coincidencias en orden) y reordená el `PATH` o eliminá el duplicado que no querés.
2. CI quiere artefactos **determinísticos, fijados y verificables**. `brew install` resuelve a la versión actual de la fórmula (que puede moverse), depende de que Homebrew esté presente en el runner y agrega sobrecarga del gestor de paquetes. El método del Ejercicio 2 fija un release exacto, verifica su SHA-256 y deja un único binario autocontenido — reproducible y auditable en cada corrida del pipeline.

### Ejercicio 4
1. El bind mount hace visibles tus archivos del host dentro del contenedor. Sin `-v "$(pwd):/work" -w /work`, el sistema de archivos del contenedor **no** contiene `require-labels.yaml` ni `deploy.yaml`, así que `kyverno apply` fallaría con un error de "file not found"/no-such-path — el contenedor parte del sistema de archivos de la imagen, que no sabe nada sobre tu directorio de trabajo del host.
2. Fijar `:v1.13.4` garantiza que cada corrida del pipeline ejecute el **exacto mismo build de la CLI**, de modo que una policy que pasa hoy pasa mañana por la misma razón. `:latest` puede cambiar silenciosamente entre corridas, convirtiendo una actualización no relacionada de la CLI en un pass/fail espurio del pipeline — un riesgo de reproducibilidad y depurabilidad.
3. El entrypoint de la imagen ya es el binario `kyverno`, así que los argumentos que pasás se le agregan. Escribir `... kyverno version` ejecutaría `kyverno kyverno version`, y `kyverno` no es un subcomando válido — la CLI daría un error como `unknown command "kyverno" for "kyverno"`. Pasás solo el subcomando (`version`, `apply`, `test`, …).

### Ejercicio 5
1. **`kyverno test`** ejecuta una suite de aserciones de prueba declarativas desde un sistema de archivos local sin clúster — ideal como gate de CI. **`kyverno apply`** aplica policies a recursos dados y reporta el conteo `pass/fail/warn/error/skip`.
2. Los CRDs de policy de Kyverno y la superficie de JMESPath/funciones personalizadas **evolucionan entre releases minor** — nuevos campos, nuevos tipos de reglas, defaults/validaciones cambiados. Si la CLI es un minor *más nuevo* que el clúster, `kyverno apply`/`test` puede aceptar localmente una policy que el controlador más viejo en el clúster rechaza o ignora silenciosamente; si es *más viejo*, la CLI puede fallar al parsear una policy que el clúster corre sin problemas. Ejemplo concreto: escribir una policy que usa un campo o función introducido en v1.13 con una CLI v1.11 (o viceversa) produce un "pass" local pero una falla de admission del lado del clúster — falsa confianza. Hacer coincidir la versión minor mantiene la validación local fiel al comportamiento del clúster.
3. El **tag de la imagen en ejecución es la fuente de verdad** de lo que realmente está admitiendo requests. Un `values.yaml` de Helm o la versión del chart puede estar desactualizado, ser sobrescrito en el momento del deploy (`--set image.tag=…`) o desviarse de lo que realmente se desplegó (patches manuales, rollbacks, digests de imagen fijados en otro lado). Leer `.spec.template.spec.containers[0].image` en el Deployment en vivo refleja la realidad desplegada, no la configuración pretendida.

</details>