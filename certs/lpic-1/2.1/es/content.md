# 2.1 Shells and Shell Scripting

## 1. Motivaci\u00f3n y Problema Arquitect\u00f3nico de Producci\u00f3n

En un mundo dominado por herramientas declarativas de Infrastructure as Code (Terraform, Ansible) y lenguajes de alto nivel (Go, Python), el **Shell Scripting** (particularmente Bash) sigue siendo el *glue code* (c\u00f3digo pegamento) universal de la infraestructura. El problema arquitect\u00f3nico principal surge en el "Day 0" (bootstrapping) y en el aislamiento de contenedores (Docker/Kubernetes). Un contenedor OCI (Open Container Initiative) m\u00ednimo a menudo no tiene Python o Go preinstalados por razones de seguridad y tama\u00f1o (superficie de ataque); sin embargo, casi siempre cuenta con un Bourne-compatible shell (como `ash` en Alpine o `bash` en Debian).

Para un SRE, escribir un Shell Script resiliente no es simplemente apilar comandos; implica manejar el control de flujo estricto, gesti\u00f3n de se\u00f1ales (SIGTERM, SIGKILL) para *graceful shutdowns* en orquestadores, manejo seguro de variables de entorno y prevenir inyecciones. Un script de Bash en producci\u00f3n que no maneja errores correctamente puede continuar ejecut\u00e1ndose tras fallar una conexi\u00f3n a base de datos, corrompiendo silenciosamente el estado de todo un cl\u00faster.

## 2. Comparativas T\u00e9cnicas y Trade-offs

### Interpretes de Comandos (Shells)

| Shell | Caracter\u00edsticas Clave | Caso de Uso en Producci\u00f3n SRE |
| :--- | :--- | :--- |
| **Bash** (Bourne Again SHell) | Soporte para arrays, sustituci\u00f3n de procesos `<()`, est\u00e1ndar de facto en Linux. | Scripts de CI/CD masivos, entrypoints complejos, utilidades de plataforma. |
| **sh / Dash / Ash** | Altamente estricto al est\u00e1ndar POSIX. Muy ligero y r\u00e1pido. Menos features. | Contenedores base (Alpine) o `initramfs`. Forzar compatibilidad estricta. |
| **Zsh / Fish** | Autocompletado heur\u00edstico, plugins, resaltado de sintaxis. | Uso **exclusivo** interactivo del usuario o workstation local. Nunca para scripts de servidores. |

### Control de Errores: Defensive Bash vs Default Bash

| Comportamiento | Script Normal (Default) | Defensive Bash (`set -euo pipefail`) |
| :--- | :--- | :--- |
| **Fallo en un comando** | El script contin\u00faa ejecutando la siguiente l\u00ednea, potencialmente siendo destructivo. | Falla y termina instant\u00e1neamente (`-e`). |
| **Variables no declaradas** | Expande a cadena vac\u00eda silenciosamente. (Ej. `rm -rf /$VAR` borra `/`). | Arroja error y detiene el script (`-u`). |
| **Pipes Ocultos** | En `cmd1 | cmd2`, si `cmd1` falla pero `cmd2` es exitoso, el script lo considera un \u00e9xito global. | Fuerza a que el pipeline falle si **cualquier** comando en la cadena falla (`-o pipefail`). |

## 3. Manifiestos, Configuraci\u00f3n e Infraestructura

### Configuraci\u00f3n: Entrypoint Resiliente para Kubernetes

Este script ilustra patrones avanzados: delegaci\u00f3n de se\u00f1ales mediante `exec`, control estricto de errores (`set -euo pipefail`) y *Variable Expansion* para valores por defecto.

```bash
#!/usr/bin/env bash
# /usr/local/bin/entrypoint.sh
# Uso: Script de inicio para pods en Kubernetes

# 1. Modo Defensivo (SRE Best Practice)
set -e          # Exit immediately on non-zero status
set -u          # Exit on undefined variables
set -o pipefail # Catch errors in pipe chains
# set -x        # (Opcional) Print trace for debugging

# 2. Asignaci\u00f3n segura de variables de entorno (Defaults)
APP_PORT="${APP_PORT:-8080}"
DB_TIMEOUT="${DB_TIMEOUT:-30}"
ENVIRONMENT="${ENVIRONMENT:=production}" # = asigna y exporta si estaba vac\u00eda

# 3. Validaci\u00f3n estricta de requerimientos
if [[ -z "${DB_PASSWORD:-}" ]]; then
    echo "[FATAL] DB_PASSWORD is not set. Refusing to start." >&2
    exit 1
fi

echo "[INFO] Iniciando aplicaci\u00f3n en entorno: $ENVIRONMENT en puerto $APP_PORT..."

# 4. Sustituci\u00f3n del proceso (Process Replacement)
# IMPORTANTE: No usamos `myapp &` ni corremos la app como hijo de bash.
# 'exec' reemplaza el proceso bash actual por 'myapp', d\u00e1ndole el PID 1.
# Esto asegura que las se\u00f1ales del kubelet (SIGTERM) lleguen directo a la app para un graceful shutdown.
exec /opt/myapp/bin/server --port "$APP_PORT" --timeout "$DB_TIMEOUT"
```

## 4. Comandos CLI y Salidas de Terminal Reales

### Gesti\u00f3n de Variables de Entorno y Alias

```bash
# Exportar una variable para que los procesos hijos la hereden
$ export KUBECONFIG="/etc/kubernetes/admin.conf"

# Ver todas las variables exportadas (el entorno)
$ env | grep KUBE
KUBECONFIG=/etc/kubernetes/admin.conf

# Definir un alias para atajos iterativos de operador
$ alias k='kubectl'
$ k get nodes
NAME       STATUS   ROLES           AGE   VERSION
worker-1   Ready    <none>          15d   v1.27.3

# Bypass temporal de un alias (ejecutando el binario original real)
$ \k
bash: k: command not found
```

### Funciones, Loops y Control de Flujo (Scripts en CLI)

Las funciones evitan repetir c\u00f3digo. Los loops son esenciales para chequeos de readiness (polling).

```bash
# Definici\u00f3n de una funci\u00f3n de polling que espera a que una API responda 200 OK
wait_for_api() {
    local endpoint="$1"
    local max_retries=5
    local count=0

    echo "Esperando a la API: $endpoint"
    while [[ $count -lt $max_retries ]]; do
        if curl -s -o /dev/null -w "%{http_code}" "$endpoint" | grep -q "200"; then
            echo "API lista."
            return 0
        fi
        echo "Intento $((count+1)) fallido. Retentando en 2s..."
        sleep 2
        ((count++))
    done
    
    echo "Timeout esperando a la API." >&2
    return 1
}

# Ejecuci\u00f3n y lectura del Exit Code especial ($?)
$ wait_for_api "http://127.0.0.1:8080/healthz"
Esperando a la API: http://127.0.0.1:8080/healthz
Intento 1 fallido. Retentando en 2s...
API lista.

$ echo $?
0
```

## 5. Gu\u00eda de Verificaci\u00f3n y Diagn\u00f3stico de Fallas

1. **Scripts ignorando Se\u00f1ales (Kubernetes Pods atascados en `Terminating`)**:
   Si un pod tarda exactamente 30 segundos (el `terminationGracePeriodSeconds` de K8s por defecto) en morir tras un despliegue, es porque tu script de bash atrap\u00f3 el PID 1, recibi\u00f3 el `SIGTERM`, y al no estar programado para manejarlo, ignor\u00f3 la se\u00f1al hasta que el orquestador envi\u00f3 un `SIGKILL`.
   *Resoluci\u00f3n:* Aseg\u00farate de iniciar tu binario final usando `exec` (ej. `exec mi_binario`) para que herede el PID 1 y las se\u00f1ales pasen directamente, o utiliza la herramienta `tini` en tu contenedor.

2. **Condicionales Rotos (`[ ]` vs `[[ ]]`)**:
   Un script falla con `too many arguments`. Esto ocurre con el comando test tradicional `[` cuando una variable contiene espacios y no est\u00e1 entrecomillada.
   *Diagn\u00f3stico:* `$ VAR="dos palabras"; [ $VAR == "test" ]` eval\u00faa como `[ dos palabras == "test" ]` lo cual es sintaxis inv\u00e1lida.
   *Resoluci\u00f3n:* En Bash moderno, utiliza siempre dobles corchetes `[[ ]]` que evitan el *Word Splitting*, o aseg\u00farate de entrecomillar variables `[ "$VAR" = "test" ]`.

3. **Bash Scripts fallando silenciosamente en CI/CD**:
   Tu pipeline de GitLab CI o GitHub Actions reporta \u00e9xito (`verde`), pero a mitad de la ejecuci\u00f3n hubo un error de descarga o compilaci\u00f3n.
   *Diagn\u00f3stico:* Los scripts de CI/CD suelen concatenar comandos. Si un comando intermedio falla pero el script llega al final y el \u00faltimo comando es exitoso, Bash devuelve exit code `0`.
   *Resoluci\u00f3n:* Fuerza el modo estricto en la primera l\u00ednea del step de CI: `set -e`.

## 6. Referencias

* LPIC-1 Objetivos (Topic 105): [https://www.lpi.org/our-certifications/exam-101-objectives](https://www.lpi.org/our-certifications/exam-101-objectives)
* Advanced Bash-Scripting Guide: [https://tldp.org/LDP/abs/html/](https://tldp.org/LDP/abs/html/)
* Bash Reference Manual (GNU): [https://www.gnu.org/software/bash/manual/bash.html](https://www.gnu.org/software/bash/manual/bash.html)
* Google Shell Style Guide: [https://google.github.io/styleguide/shellguide.html](https://google.github.io/styleguide/shellguide.html)