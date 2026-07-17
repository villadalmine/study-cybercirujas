# CKS 6.1 — Perform behavioral analytics to detect malicious activities

**Peso en el examen:** 4

**Fuentes de referencia:**
- CNCF CKS Curriculum v1.34 — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Falco (runtime threat detection, proyecto CNCF) — https://falco.org/docs/
- Falco default rules — https://github.com/falcosecurity/rules
- Falco Helm chart — https://github.com/falcosecurity/charts

El análisis de comportamiento (behavioral analytics) en Kubernetes se implementa en la práctica con **Falco**, que observa syscalls a nivel de kernel (vía eBPF o kernel module) y las compara contra reglas declarativas para detectar patrones anómalos: shells interactivas inesperadas, escrituras en rutas sensibles, herramientas de red no autorizadas, acceso al API server desde pods que no deberían necesitarlo, etc.

Los ejercicios asumen un cluster con al menos un nodo worker donde tengas permisos de `cluster-admin` (kind, minikube o un cluster de práctica similar).

---

## Ejercicio 1 — Instalar Falco en el cluster

1. Agregá el repositorio Helm de Falco y actualizalo:
   ```bash
   helm repo add falcosecurity https://falcosecurity.github.io/charts
   helm repo update
   ```
2. Creá un namespace dedicado:
   ```bash
   kubectl create namespace falco
   ```
3. Instalá Falco con el driver `modern_ebpf` (no requiere compilar módulos de kernel):
   ```bash
   helm install falco falcosecurity/falco \
     --namespace falco \
     --set driver.kind=modern_ebpf \
     --set tty=true
   ```
4. Verificá que el DaemonSet esté corriendo en todos los nodos:
   ```bash
   kubectl get pods -n falco -o wide
   ```
5. Seguí los logs en vivo:
   ```bash
   kubectl logs -n falco -l app.kubernetes.io/name=falco -f
   ```

**Preguntas:**
- ¿Por qué Falco se despliega como **DaemonSet privilegiado** en cada nodo en vez de como un Deployment normal?
- ¿Qué diferencia práctica hay entre el driver `kernel module`, el `ebpf` clásico y el `modern_ebpf` en cuanto a requisitos del nodo y superficie de riesgo?

---

## Ejercicio 2 — Explorar la estructura de las reglas por defecto

1. Listá los ConfigMaps creados por el chart:
   ```bash
   kubectl get cm -n falco
   ```
2. Volcá el contenido del ConfigMap de reglas (el nombre exacto depende de la versión del chart, típicamente `falco-rules`):
   ```bash
   kubectl get cm falco-rules -n falco -o yaml | less
   ```
3. Identificá en el archivo los tres tipos de bloque: `list`, `macro` y `rule`.
4. Buscá la regla `Terminal shell in container`:
   ```bash
   kubectl get cm falco-rules -n falco -o yaml | grep -A 15 "Terminal shell in container"
   ```
5. Anotá los campos `condition`, `output` y `priority` de esa regla.

**Preguntas:**
- ¿Qué rol cumple una `macro` dentro de una regla de Falco, y por qué conviene reutilizarlas en vez de repetir la misma condición en varias reglas?
- ¿Qué controla el campo `priority` de una regla, y cómo se usa habitualmente para filtrar el volumen de alertas que llega a un sink externo?

---

## Ejercicio 3 — Disparar una alerta con una regla por defecto

1. Creá un pod de prueba:
   ```bash
   kubectl run victim --image=nginx:1.25 -n falco --restart=Never
   kubectl wait --for=condition=Ready pod/victim -n falco
   ```
2. En una terminal, seguí los logs de Falco filtrando por "shell":
   ```bash
   kubectl logs -n falco -l app.kubernetes.io/name=falco -f | grep -i shell
   ```
3. En otra terminal, abrí una shell interactiva dentro del pod:
   ```bash
   kubectl exec -it victim -n falco -- /bin/bash
   ```
4. Volvé a la terminal de logs y observá la alerta generada por la regla `Terminal shell in container`.
5. Identificá en el output los campos `user`, `container`, `command` (`proc.cmdline`), `k8s.ns.name` y `k8s.pod.name`.

**Preguntas:**
- ¿Por qué `kubectl exec` hacia una shell interactiva se marca por defecto como comportamiento sospechoso, incluso cuando lo ejecuta un administrador legítimo?
- ¿Qué campo del output de la alerta te permite identificar el Pod y namespace de origen sin correlacionar manualmente con `kubectl get pods`?

---

## Ejercicio 4 — Detectar acceso sospechoso al API server desde un Pod

1. Desde dentro del pod `victim`, intentá contactar al API server (algo que un Pod de aplicación normal no debería necesitar hacer):
   ```bash
   kubectl exec -it victim -n falco -- curl -sk https://kubernetes.default.svc/api --max-time 3
   ```
2. Vas a recibir un `403` (falta el token/RBAC), pero la conexión de red igual ocurre y Falco la observa a nivel de syscall.
3. Revisá los logs de Falco de los últimos minutos buscando coincidencias:
   ```bash
   kubectl logs -n falco -l app.kubernetes.io/name=falco --since=2m | grep -i "api server"
   ```
4. Anotá el nombre exacto de la regla (`rule`) y la `priority` que reportó tu instalación (puede variar según la versión del ruleset).

**Preguntas:**
- ¿Por qué acceder al API server desde un Pod que no forma parte del control plane se considera un patrón típico de reconocimiento post-explotación?
- Si este paso no generó ninguna alerta en tu cluster, ¿qué dos causas deberías investigar primero?

---

## Ejercicio 5 — Escribir una regla custom

1. Creá un archivo `custom-rules.yaml` que detecte la ejecución de herramientas de red asociadas a reverse shells dentro de containers:
   ```yaml
   - rule: Netcat Executed in Container
     desc: Detecta la ejecución de netcat u otra herramienta de conexión remota dentro de un container, comportamiento típico de reverse shells.
     condition: >
       spawned_process and container and
       proc.name in (nc, ncat, netcat, socat)
     output: >
       Posible reverse shell - herramienta de red ejecutada en container
       (user=%user.name command=%proc.cmdline container=%container.name
       image=%container.image.repository pod=%k8s.pod.name ns=%k8s.ns.name)
     priority: CRITICAL
     tags: [network, mitre_execution, container]
   ```
2. Aplicá la regla actualizando el release de Helm:
   ```bash
   helm upgrade falco falcosecurity/falco -n falco --reuse-values \
     --set-file customRules.custom-rules\.yaml=./custom-rules.yaml
   ```
3. Confirmá que no hubo errores de parseo en el reinicio del DaemonSet:
   ```bash
   kubectl logs -n falco -l app.kubernetes.io/name=falco | grep -i "custom-rules\|error"
   ```
4. Probá la regla instalando `netcat` dentro de un pod liviano:
   ```bash
   kubectl run tester --image=alpine -n falco --restart=Never -- sleep 3600
   kubectl exec -it tester -n falco -- sh -c "apk add --no-cache netcat-openbsd && nc -h"
   ```
5. Confirmá en los logs de Falco que se disparó la alerta `CRITICAL` con el pod y comando correctos.

**Preguntas:**
- ¿Por qué sería un error escribir la condición como `proc.name in (nc, ncat, netcat, socat)` sin incluir la macro `container`, en un cluster donde Falco también corre sobre el host?
- ¿Qué ventaja concreta tiene marcar esta regla como `CRITICAL` en lugar de `WARNING` cuando las alertas se enrutan a un sistema externo (por ejemplo, Slack o PagerDuty vía falcosidekick)?

---

## Ejercicio 6 — Reducir falsos positivos con excepciones

1. Supongamos que un pod legítimo de diagnóstico (`netshoot-debug`) usa `nc` de forma habitual y genera ruido constante.
2. Agregá una `exception` a la regla del ejercicio anterior en vez de deshabilitarla o duplicarla:
   ```yaml
   - rule: Netcat Executed in Container
     ...
     exceptions:
       - name: allowed_netshoot
         fields: [k8s.pod.name, k8s.ns.name]
         comps: [=, =]
         values:
           - [netshoot-debug, falco]
   ```
3. Volvé a aplicar con `helm upgrade` (mismo comando del paso 2 del ejercicio anterior).
4. Repetí la prueba de `nc` desde `netshoot-debug` y confirmá que ya no genera alerta, mientras que el pod `tester` sigue disparándola.

**Preguntas:**
- ¿Qué diferencia hay entre resolver un falso positivo con una `exception` de la regla y simplemente bajarle la `priority`?
- ¿Por qué el mecanismo de `exceptions` es preferible a mantener una copia editada y duplicada de la regla original?

---

## Ejercicio 7 (estilo examen) — Investigar un incidente a partir de logs de Falco

1. Filtrá únicamente las alertas de prioridad `Critical` o `Error` de los últimos 10 minutos:
   ```bash
   kubectl logs -n falco -l app.kubernetes.io/name=falco --since=10m | grep -E "Critical|Error"
   ```
2. Para cada alerta relevante, extraé namespace y pod del output (formato texto o JSON según config):
   ```bash
   kubectl logs -n falco -l app.kubernetes.io/name=falco --since=10m \
     | grep -oE 'k8s.ns.name=[^ ]+|k8s.pod.name=[^ ]+'
   ```
3. Confirmá que el pod identificado sigue activo:
   ```bash
   kubectl get pod <pod> -n <ns>
   ```
4. Como contención inmediata, eliminá el pod comprometido:
   ```bash
   kubectl delete pod <pod> -n <ns> --grace-period=0 --force
   ```
5. Documentá el hallazgo revisando los eventos del namespace:
   ```bash
   kubectl get events -n <ns> --sort-by=.lastTimestamp | tail
   ```

**Preguntas:**
- Si en el examen la tarea pide identificar y **aislar** el pod que generó la alerta sin eliminarlo (para preservarlo con fines forenses), ¿qué mecanismo usarías en su lugar?
- ¿Por qué `--grace-period=0 --force` no es una buena primera acción si tu objetivo es preservar evidencia forense del contenedor comprometido?

---

<details>
<summary><strong>Ver respuestas</strong></summary>

**Ejercicio 1**
- Falco necesita observar syscalls de *todos* los procesos del nodo (no solo los de un container aislado), lo cual requiere acceso directo al kernel vía eBPF o un kernel module, más acceso a `/proc`, `/dev` y los namespaces del host. Un Deployment normal, confinado a su propio container, no tiene esa visibilidad. Por eso corre como DaemonSet privilegiado: garantiza una instancia por nodo con los privilegios necesarios.
- El **kernel module** ofrece el máximo rendimiento pero requiere compilar/cargar un módulo firmado para la versión exacta del kernel (mayor fricción y mayor superficie de ataque en el kernel). El **eBPF clásico** evita compilar módulos pero necesita headers del kernel o un probe preconstruido. El **modern_ebpf** usa CO-RE (Compile Once, Run Everywhere) con el eBPF verifier del kernel moderno (≥5.8 aprox.), sin necesidad de artefactos específicos por kernel, y es el más portable y con menor privilegio requerido.

**Ejercicio 2**
- Una `macro` es una condición reutilizable con nombre (por ejemplo `spawned_process` o `container`) que se referencia desde múltiples reglas. Evita duplicar lógica, centraliza el mantenimiento (si cambia la forma de detectar "estar dentro de un container", se corrige en un solo lugar) y hace las reglas más legibles.
- `priority` clasifica la severidad de la alerta (`Emergency` a `Debug`, siguiendo niveles de syslog). Se usa para filtrar: por ejemplo, enrutar solo `Critical`/`Error` a un canal de PagerDuty, mientras que `Warning`/`Notice` van a un log de auditoría de menor urgencia.

**Ejercicio 3**
- Aunque `kubectl exec` sea una acción administrativa legítima, desde el punto de vista del kernel del nodo es indistinguible de un atacante que obtuvo una shell dentro de un container tras explotar una vulnerabilidad. Falco no puede evaluar intención, solo comportamiento; por eso la regla por defecto asume que una shell interactiva dentro de un container de producción es anómala y debe revisarse, incluso si termina siendo un falso positivo válido (acción de un admin).
- Los campos `k8s.ns.name` y `k8s.pod.name` (parte de los `output_fields` del evento) identifican directamente el namespace y pod de origen, sin necesidad de cruzar el `container.id` con `kubectl get pods -A -o wide` manualmente.

**Ejercicio 4**
- Un Pod de aplicación (por ejemplo, un frontend web) normalmente no necesita hablar con el API server: solo lo hacen controllers, operators o pods con lógica de gestión del cluster. Cuando un atacante compromete un container, uno de los primeros pasos típicos de reconocimiento es consultar el API server (con el ServiceAccount token montado por defecto) para enumerar permisos, secrets o moverse lateralmente — por eso ese tráfico, viniendo de un pod "común", es una señal fuerte de post-explotación.
- Primero: verificar que la regla correspondiente esté efectivamente habilitada en el ruleset instalado (algunas versiones la tienen deshabilitada por defecto o con `priority` filtrada aguas abajo del sink). Segundo: confirmar que el tráfico realmente llegó a nivel de syscall — una `NetworkPolicy` que bloquee la conexión antes de que se complete podría impedir que se cumpla la condición exacta de la regla (según cómo esté definida sobre `evt.type=connect`).

**Ejercicio 5**
- Sin la macro `container`, la regla también se dispararía para procesos `nc`/`socat` ejecutados directamente en el host (por ejemplo, por un administrador de nodo o por el propio tooling de infraestructura), generando falsos positivos fuera del alcance que se quiere vigilar (comportamiento dentro de containers).
- Con `CRITICAL`, un pipeline de alertas típico (vía falcosidekick u otro forwarder) puede enrutar automáticamente esa severidad a un canal de respuesta inmediata (PagerDuty, Slack de guardia), mientras que prioridades menores solo se acumulan en un dashboard o log para revisión periódica. Fijar la severidad correctamente evita tanto el "alert fatigue" como la pérdida de una señal crítica entre ruido de baja prioridad.

**Ejercicio 6**
- Bajar la `priority` reduce la severidad de la alerta para **todos** los casos que matcheen la regla (incluidos los realmente maliciosos), perdiendo capacidad de detección real. Una `exception` en cambio excluye selectivamente un contexto conocido y legítimo (ese pod/namespace puntual) sin afectar la sensibilidad de la regla para el resto del cluster.
- Mantener una copia editada duplica la regla original: cualquier actualización del ruleset upstream (por ejemplo, al actualizar la versión de Falco) no se propaga a la copia, y con el tiempo ambas versiones divergen. Una `exception` se declara sobre la regla original, así que se sigue beneficiando de mejoras futuras en su `condition` u `output`.

**Ejercicio 7**
- Aplicar una `NetworkPolicy` que deniegue todo el tráfico de ingreso y egreso hacia ese pod específico (o remover sus labels del selector del Service para sacarlo de los endpoints) lo aísla de la red sin eliminarlo, preservando el filesystem del container y los procesos en memoria para un análisis forense posterior (por ejemplo, con `kubectl debug` o copiando el filesystem con `kubectl cp`).
- `--grace-period=0 --force` termina el pod de inmediato, lo que destruye el estado en memoria del proceso (útil para forense de malware activo) y el filesystem del container (a menos que se haya usado un volumen persistente o se haya capturado antes). Además, elimina cualquier evidencia efímera antes de poder inspeccionarla, comprometiendo la investigación del incidente.

</details>