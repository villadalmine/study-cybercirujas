# Examen LPIC-3 303-300 (v3.0) — Tema 3.1: Seguridad de Aplicaciones

---

## 1. Motivación Arquitectónica de Producción y Planteamiento del Problema

Las cargas de trabajo empresariales modernas nativas de la nube y Linux se ejecutan dentro de entornos multinquilino (multi-tenant) complejos donde la capa de aplicación representa la mayor superficie de ataque. Las vulnerabilidades que operan en la capa de aplicación, que van desde corrupciones de memoria binaria (buffer overflows, cadenas de Return-Oriented Programming [ROP]) hasta vectores de aplicaciones web (SQL Injection, Remote Code Execution [RCE], Server-Side Request Forgery [SSRF]), pueden derivar en ejecución remota no autorizada, exfiltración de datos y escalada lateral de privilegios hacia el espacio de kernel del host.

```
                     [ PUBLIC UNTRUSTED TRAFFIC ]
                                  │
                                  ▼
┌──────────────────────────────────────────────────────────────────┐
│  REVERSE PROXY & WAF LAYER (ModSecurity v3 + OWASP CRS v4)       │
│  - Inspects HTTP Request Payload / Headers                       │
│  - Terminates TLS 1.3 / Enforces HSTS & CSP                      │
│  - Blocks Injection, XSS, SSRF, & Malformed Requests             │
└─────────────────────────────────┬────────────────────────────────┘
                                  │ Sanitized L7 Traffic
                                  ▼
┌──────────────────────────────────────────────────────────────────┐
│  RUNTIME CONTAINER ISOLATION (Namespaces, cgroups v2, UserNS)   │
│  - Unprivileged UID Mapping (UID 10001:10001)                    │
│  - Read-Only Root Filesystem (`/` mounted ro)                    │
│  - Capabilities Dropped (`CapDrop: ALL`)                         │
└─────────────────────────────────┬────────────────────────────────┘
                                  │ Syscall Execution
                                  ▼
┌──────────────────────────────────────────────────────────────────┐
│  KERNEL SYSCALL FILTERING (Seccomp-BPF + ASLR + DEP/NX)          │
│  - ASLR: `/proc/sys/kernel/randomize_va_space = 2`               │
│  - Seccomp Profile: Filters 300+ dangerous syscalls to minimal   │
│  - Traps unauthorized `ptrace`, `kexec_load`, or `unshare`       │
└──────────────────────────────────────────────────────────────────┘
```

Una arquitectura robusta de seguridad de aplicaciones aplica **Defensa en Profundidad** (Defense-in-Depth) a lo largo de tres límites fundamentales:

1. **Kernel Space & Memory Protection**: Hardening del esquema de memoria del kernel de Linux mediante Address Space Layout Randomization (ASLR), Data Execution Prevention (DEP/NX), Position Independent Executables (PIE) y Relocation Read-Only (RELRO) para anular las cargas útiles (payloads) de exploits incluso si existen errores en el código.
2. **Process Runtime Isolation**: Restricción de las capabilities de los procesos a través de Linux Namespaces (PID, MNT, NET, IPC, UTS, USER, CGROUP), límites de recursos de cgroups v2, eliminación de POSIX Capabilities (`CAP_SYS_ADMIN`, `CAP_NET_RAW`) y reducción de la superficie de syscalls mediante filtros Seccomp-BPF.
3. **Application & Boundary Filtering**: Despliegue de Web Application Firewalls (WAF) de Capa 7 integrados en reverse proxies de alto rendimiento (NGINX + ModSecurity v3) para analizar, sanitizar y bloquear payloads maliciosos de aplicaciones L7 antes de que alcancen los runtimes de ejecución.

El fallo al asegurar cualquiera de las capas invalida todo el modelo de confianza, permitiendo que los procesos de aplicación comprometidos realicen un breakout hacia los namespaces del host o ejecuten shellcode arbitrario.

---

## 2. Tablas de Comparación Técnica y Análsis de Compromisos

### Tabla 1: Mecanismos de Protección de Memoria del Kernel y Binarios

| Mecanismo | Capa de Operación | Principal Amenaza Mitigada | Overhead de Rendimiento | Compromiso Operativo / Modo de Fallo |
| :--- | :--- | :--- | :--- | :--- |
| **ASLR** (`randomize_va_space=2`) | Kernel / MMU | Predicción de ubicación de memoria, Buffer Overflows, ROP | Despreciable (<0.1%) | Requiere binarios compilados con `-fPIE -pie`. Incompatible con punteros estáticos no-PIE heredados. |
| **DEP / NX** | Hardware de CPU / MMU | Ejecución de código desde regiones Stack/Heap | Cero (Aplicado por hardware) | Previene compiladores JIT o motores de ejecución dinámica a menos que se asignen páginas de memoria ejecutables explícitas (`PROT_EXEC`). |
| **Full RELRO** | Linker / Binario | Ataques de sobrescritura de GOT (Global Offset Table) | Ligero incremento en el tiempo de inicialización del proceso | Todos los símbolos dinámicos se resuelven en el tiempo de carga (`LD_BIND_NOW=1`). Previene la optimización de lazy binding. |
| **Stack Canaries** (`-fstack-protector-strong`) | Compilador / Runtime | Sobrescritura de dirección de retorno por stack buffer overflow | ~1% overhead de CPU | Desencadena la terminación inmediata del proceso (`SIGABRT`) ante el fallo de verificación del guardián, resultando en un crash de la aplicación (DoS sobre RCE). |
| **Seccomp-BPF** | Kernel / Entrada de Syscall | Explotación no intencionada de la interfaz del kernel (`sys_ptrace`, `kexec`) | ~1-3% por evaluación de syscall | Los bloqueos de syscall por falsos positivos resultan en la finalización inmediata del proceso mediante `SIGSYS`. Requiere un profiling riguroso de syscalls. |

---

### Tabla 2: Paradigmas de Aislamiento de Procesos y Runtime

| Mecanismo de Aislamiento | Límite de Seguridad | Superficie Expuesta del Kernel | Complejidad de Mantenimiento | Adecuación de Despliegue |
| :--- | :--- | :--- | :--- | :--- |
| **Chroot Jail** | Virtualización de Rutas de Archivo | Interfaz completa de syscalls del kernel | Baja | Daemons monolíticos heredados. Fácilmente evadible si se ejecuta como `root` (UID 0) a través de `chdir()` + `chroot()`. |
| **Linux Namespaces + Capabilities** | Aislamiento de Vista de Procesos | Interfaz compartida amplia del kernel | Media | Contenedores OCI estándar (Docker/CRI-O). Requiere la eliminación explícita de Linux capabilities (`CAP_SYS_ADMIN`). |
| **Filtrado Seccomp-BPF** | Interfaz de Llamadas al Sistema | Subconjunto restringido de llamadas al sistema | Alta (Requiere auditoría) | Microservicios de alta seguridad. Restringe la exposición a vulnerabilidades del kernel denegando syscalls innecesarias. |
| **AppArmor / SELinux (MAC)** | Seguridad por Ruta / Etiqueta | Capa de Control de Acceso a Objetos | Muy Alta | Hardening de hosts en OS empresariales. Obligatorio para el cumplimiento regulatorio (PCI-DSS, NIST SP 800-53). |

---

### Tabla 3: Estrategias de Integración de Seguridad L7 de Aplicaciones y WAF

| Estrategia | Posición en la Arquitectura | Impacto en Latencia | Capacidad de Inspección | Riesgo de Falsos Positivos |
| :--- | :--- | :--- | :--- | :--- |
| **ModSecurity v3 + OWASP CRS** | Reverse Proxy (Módulo NGINX/Envoy) | +2ms a +15ms por petición | L7 Profunda (HTTP Body, Headers, URI, Cookies) | Medio-Alto (Requiere ajuste de reglas y modificaciones del umbral de anomalías). |
| **Filtrado eBPF L7** | Capa de Sockets del Kernel (tc/cgroup bpf) | <0.5ms | Headers de Protocolo L4/L7, Estado de Sockets | Bajo para L4, alta complejidad de implementación para inspección profunda de HTTP body. |
| **Verificación In-Line en API Gateway** | Borde de la Aplicación | +5ms a +20ms | Validación de JWT, Validación de Esquema, Rate Limiting | Bajo (Validación basada en esquemas contra especificación OpenAPI). |

---

## 3. Manifiestos de Producción Completos y Configuraciones de Infraestructura

### 3.1 Web Application Firewall NGINX Asegurado (`/etc/nginx/nginx.conf`)

Esta configuración de producción integra **ModSecurity v3** con el **OWASP Core Rule Set (CRS)**, impone **TLS 1.3**, cabeceras de respuesta HTTP strictly seguras (HSTS, CSP, X-Frame-Options) y zonas de limitación de tasa (rate-limiting) aseguradas.

```nginx
user nginx;
worker_processes auto;
worker_rlimit_nofile 65535;
pid /var/run/nginx.pid;

include /usr/share/nginx/modules/*.conf;

events {
    worker_connections 8192;
    use epoll;
    multi_accept on;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format security_audit '$remote_addr - $remote_user [$time_local] "$request" '
                              '$status $body_bytes_sent "$http_referer" '
                              '"$http_user_agent" "$http_x_forwarded_for" '
                              'ModSecStatus=$modsecurity_status ModSecRuleID=$modsecurity_rule_id';

    access_log /var/log/nginx/access_log.log security_audit;
    error_log  /var/log/nginx/error_log.log warn;

    # Information Disclosure Hardening
    server_tokens off;
    more_clear_headers Server;

    # Buffer Limits against Buffer Overflow & Slowloris DoS
    client_body_buffer_size 128k;
    client_max_body_size 10m;
    client_header_buffer_size 1k;
    large_client_header_buffers 4 8k;
    client_body_timeout 10s;
    client_header_timeout 10s;
    keepalive_timeout 30s;
    send_timeout 10s;

    # Rate Limiting Zones
    limit_req_zone $binary_remote_addr zone=api_limit:10m rate=10r/s;
    limit_conn_zone $binary_remote_addr zone=conn_limit:10m;

    # ModSecurity v3 WAF Global Engine Initialization
    modsecurity on;
    modsecurity_rules_file /etc/nginx/modsec/main.conf;

    # Optimized I/O
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;

    # TLS Security Policy
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    ssl_stapling on;
    ssl_stapling_verify on;

    server {
        listen 443 ssl http2;
        listen [::]:443 ssl http2;
        server_name app.production.internal;

        ssl_certificate /etc/ssl/certs/app_production.crt;
        ssl_certificate_key /etc/ssl/private/app_production.key;
        ssl_dhparam /etc/ssl/certs/dhparam.pem;

        # Mandatory HTTP Security Response Headers
        add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
        add_header X-Frame-Options "DENY" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-XSS-Protection "0" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;
        add_header Content-Security-Policy "default-src 'self'; script-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none';" always;
        add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;

        location / {
            limit_req zone=api_limit burst=20 nodelay;
            limit_conn conn_limit 10;

            proxy_pass http://127.0.0.1:8080;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;

            # Proxy Buffer Protections
            proxy_buffering on;
            proxy_buffer_size 4k;
            proxy_buffers 8 8k;
        }

        # Block direct access to hidden files
        location ~ /\. {
            deny all;
            access_log off;
            log_not_found off;
        }
    }
}
```

---

### 3.2 Configuración del Núcleo de ModSecurity (`/etc/nginx/modsec/main.conf`)

Esta configuración incluye los parámetros base del motor y carga el **OWASP Core Rule Set (CRS v3.3/v4.0)** operando en **Anomaly Scoring Mode**.

```apache
# Include Base ModSecurity Configuration
Include /etc/nginx/modsec/modsecurity.conf

# OWASP CRS Engine Setup Configuration
Include /etc/nginx/modsec/coreruleset/crs-setup.conf

# OWASP CRS Rules inclusion
Include /etc/nginx/modsec/coreruleset/rules/*.conf
```

Donde `/etc/nginx/modsec/modsecurity.conf` define las anulaciones operativas clave:

```apache
# Enable Rule Engine
SecRuleEngine On
SecRequestBodyAccess On

# Request Body Limits
SecRequestBodyLimit 10485760
SecRequestBodyNoFilesLimit 131072
SecRequestBodyLimitAction Reject

# Audit Logging Configuration
SecAuditEngine RelevanceOnly
SecAuditLogRelevantStatus "^(?:5|(?:4(?!(?:04|03))))"
SecAuditLogParts ABIJDEFHZ
SecAuditLogType Serial
SecAuditLog /var/log/nginx/modsec_audit.log

# Argument Separator & UTF-8 Validation
SecArgumentSeparator &
SecCookieFormat 0
```

---

### 3.3 Perfil Seccomp BPF Personalizado para Producción (`/var/lib/kubelet/seccomp/profiles/restricted-microservice.json`)

Este documento JSON especifica un filtro seccomp basado en lista blanca (whitelist) que deniega todas las llamadas al sistema peligrosas (tales como `ptrace`, `sys_kexec_load`, `process_vm_writev`, `unshare`, `init_module`) al tiempo que permite explícitamente las llamadas requeridas para los runtimes de microservicios.

```json
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "architectures": [
    "SCMP_ARCH_X86_64",
    "SCMP_ARCH_X86",
    "SCMP_ARCH_AARCH64"
  ],
  "syscalls": [
    {
      "names": [
        "accept",
        "accept4",
        "access",
        "arch_prctl",
        "bind",
        "brk",
        "clock_gettime",
        "clone",
        "close",
        "connect",
        "epoll_create1",
        "epoll_ctl",
        "epoll_pwait",
        "epoll_wait",
        "execve",
        "exit",
        "exit_group",
        "fcntl",
        "fstat",
        "futex",
        "getcwd",
        "getdents64",
        "getegid",
        "geteuid",
        "getgid",
        "getpeername",
        "getpid",
        "getppid",
        "getsockname",
        "getsockopt",
        "getuid",
        "listen",
        "lseek",
        "madvise",
        "mmap",
        "mprotect",
        "munmap",
        "nanosleep",
        "pipe2",
        "poll",
        "read",
        "readlink",
        "recvfrom",
        "recvmmsg",
        "recvmsg",
        "rt_sigaction",
        "rt_sigprocmask",
        "rt_sigreturn",
        "sched_yield",
        "sendmmsg",
        "sendmsg",
        "sendto",
        "set_robust_list",
        "set_tid_address",
        "setsockopt",
        "shutdown",
        "socket",
        "stat",
        "write",
        "writev"
      ],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
```

---

### 3.4 Manifiesto de Deployment de Kubernetes Asegurado para Producción (`deployment-hardened.yaml`)

Este Deployment completo aplica los **Pod Security Standards (Restricted profile)**, incluyendo sistemas de archivos raíz de solo lectura, eliminación de todas las POSIX capabilities, ejecución como usuario no-root y vinculación del perfil Seccomp personalizado.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-processor
  namespace: production-finance
  labels:
    app.kubernetes.io/name: payment-processor
    app.kubernetes.io/part-of: financial-platform
    app.kubernetes.io/managed-by: gitops
spec:
  replicas: 3
  selector:
    matchLabels:
      app: payment-processor
  template:
    metadata:
      labels:
        app: payment-processor
    spec:
      serviceAccountName: payment-processor-sa
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: Localhost
          localhostProfile: profiles/restricted-microservice.json
      containers:
        - name: payment-api
          image: internal-registry.enterprise.io/finance/payment-api:v2.4.1@sha256:a5b4c3d2e1f0123456789abcdef0123456789abcdef0123456789abcdef01234
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 10001
            runAsGroup: 10001
            capabilities:
              drop:
                - ALL
          ports:
            - containerPort: 8080
              name: http-api
              protocol: TCP
          resources:
            limits:
              cpu: "1"
              memory: "512Mi"
            requests:
              cpu: "250m"
              memory: "128Mi"
          volumeMounts:
            - name: tmp-volume
              mountPath: /tmp
            - name: cache-volume
              mountPath: /var/cache/app
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /livez
              port: 8080
            initialDelaySeconds: 10
            periodSeconds: 15
      volumes:
        - name: tmp-volume
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
        - name: cache-volume
          emptyDir:
            medium: Memory
            sizeLimit: 128Mi
```

---

## 4. Comandos Reales de CLI y Salidas de Terminal Esperadas ($)

### 4.1 Verificación del Hardening de Memoria de Host y Kernel (ASLR y Banderas de Binarios)

**Verificar el parámetro ASLR del kernel mediante `sysctl`:**

```bash
$ sysctl kernel.randomize_va_space
kernel.randomize_va_space = 2
```

**Verificar las banderas de seguridad de compilación del binario usando `checksec`:**

```bash
$ checksec --file=/usr/bin/nginx
[*] '/usr/bin/nginx'
    RELRO:    Full RELRO
    Stack:    Canary found
    NX:       NX enabled
    PIE:      PIE enabled
    Fortify:  Enabled
```

**Inspeccionar el mapeo de memoria del proceso para confirmar la ejecución de ASLR (Ejecutar dos veces para confirmar direcciones base dinámicas):**

```bash
$ grep -E "heap|stack" /proc/$(pgrep -n nginx)/maps
55e4b1a23000-55e4b1a45000 rw-p 00000000 00:00 0                          [heap]
7ffca9f52000-7ffca9f73000 rw-p 00000000 00:00 0                          [stack]

$ grep -E "heap|stack" /proc/$(pgrep -n nginx)/maps
5612f8e12000-5612f8e34000 rw-p 00000000 00:00 0                          [heap]
7ffe3b121000-7ffe3b142000 rw-p 00000000 00:00 0                          [stack]
```
*(Nota: Las direcciones `55e4b...` vs `5612f...` difieren entre invocaciones, lo que confirma el ASLR activo).*

---

### 4.2 Simulación de Ataques a Aplicaciones Web y Verificación de Intercepción por WAF

**Simular un intento de SQL Injection (SQLi) mediante `curl`:**

```bash
$ curl -i -s -k -X GET "https://app.production.internal/api/v1/users?id=1%27%20OR%20%271%27%3D%271"
HTTP/2 403 
server: nginx
date: Thu, 06 Aug 2026 17:30:00 GMT
content-type: text/html
content-length: 153
x-frame-options: DENY
x-content-type-options: nosniff

<html>
<head><title>403 Forbidden</title></head>
<body>
<center><h1>403 Forbidden</h1></center>
<hr><center>nginx</center>
</body>
</html>
```

**Inspeccionar la entrada en el audit log de ModSecurity para el ataque interceptado:**

```bash
$ tail -n 25 /var/log/nginx/modsec_audit.log
---0a3f8c12-A--
[06/Aug/2026:17:30:00 +0000] 192.168.1.50 49210 10.0.0.10 443
---0a3f8c12-B--
GET /api/v1/users?id=1%27%20OR%20%271%27%3D%271 HTTP/2.0
Host: app.production.internal
User-Agent: curl/7.88.1
Accept: */*

---0a3f8c12-F--
HTTP/2 403
Content-Length: 153
Content-Type: text/html

---0a3f8c12-H--
ModSecurity: Warning. Detected SQL Injection (SQLi) attack [file "/etc/nginx/modsec/coreruleset/rules/REQUEST-942-APPLICATION-ATTACK-SQLI.conf"] [line "124"] [id "942100"] [msg "SQL Injection Attack Detected via libinjection"] [data "Matched Data: 1' OR '1'='1 found within ARGS:id"] [severity "CRITICAL"] [tag "application-multi"] [tag "language-multi"] [tag "platform-multi"] [tag "attack-sqli"]
ModSecurity: Access denied with code 403 (phase 2). Primary Anomaly Score: 15, Threshold: 5.
---0a3f8c12-Z--
```

---

### 4.3 Auditoría de Capabilities de Procesos en Runtime de Contenedores y Estados Seccomp

**Inspeccionar el estado del Security Context de un Pod de Kubernetes en ejecución:**

```bash
$ kubectl get pod -n production-finance -l app=payment-processor -o jsonpath='{.items[0].spec.containers[0].securityContext}' | jq .
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

**Verificar el modo Seccomp activo y las capabilities efectivas del proceso del contenedor a través del OS host:**

```bash
$ PID=$(pgrep -f "payment-api")
$ cat /proc/$PID/status | grep -E "Uid|Gid|CapInh|CapPrm|CapEff|CapBnd|Seccomp"
Uid:	10001	10001	10001	10001
Gid:	10001	10001	10001	10001
CapInh:	0000000000000000
CapPrm:	0000000000000000
CapEff:	0000000000000000
CapBnd:	0000000000000000
Seccomp:	2
```
*(Indicador clave: `Seccomp: 2` representa `SECCOMP_MODE_FILTER` [Seccomp-BPF activo]. `CapEff: 0000000000000000` confirma la presencia de cero capabilities elevadas).*

---

## 5. Guía de Verificación y Diagnóstico de Fallos

```
                         [ TROUBLESHOOTING FLOW ]
                                    │
          ┌─────────────────────────┴─────────────────────────┐
          ▼                                                   ▼
[ ISSUE A: SYSCALL BLOCK ]                         [ ISSUE B: READ-ONLY FS ]
   Process killed by `SIGSYS`                         Container CrashLoopBackOff
          │                                                   │
          ▼                                                   ▼
1. Query `dmesg | grep audit`                       1. Run `kubectl logs <pod>`
2. Extract syscall number                           2. Check for `EROFS` error
3. Resolve via `ausyscall <nr>`                     3. Identify write directory
4. Update `seccomp.json` whitelist                  4. Add `emptyDir` mount
```

### 5.1 Diagnóstico de Violaciones de Syscalls en Seccomp (Bloqueos por `SIGSYS`)

Cuando una aplicación intenta ejecutar una syscall no permitida bajo un perfil estricto de lista blanca (whitelist) de Seccomp BPF, el kernel termina inmediatamente el proceso mediante `SIGSYS` (Señal 31).

#### Paso 1: Monitorear los audit logs del kernel en busca de syscalls bloqueadas
Ejecute `dmesg` o monitoree `journalctl` filtrando por registros de auditoría:

```bash
$ journalctl -k -g "type=1326" --no-pager -n 5
Aug 06 17:42:10 node-01.prod kernel: audit: type=1326 audit(1722966130.412:981): auid=4294967295 uid=10001 gid=10001 ses=4294967295 pid=84102 comm="payment-api" exe="/app/payment-api" sig=31 arch=c000003e syscall=203 compat=0 ip=7f8b91012a41 code=0x00000000
```

#### Paso 2: Mapear el número de syscall a su nombre
Utilice `ausyscall` para resolver el número de syscall de la arquitectura (por ejemplo, `syscall=203` en `arch=c000003e` [x86_64]):

```bash
$ ausyscall x86_64 203
sched_setaffinity
```

#### Paso 3: Resolución
Si `sched_setaffinity` es requerido por el runtime del proceso (por ejemplo, el scheduling de hilos en Go o Java), añada `"sched_setaffinity"` al arreglo de syscalls permitidas dentro de `/var/lib/kubelet/seccomp/profiles/restricted-microservice.json` y recargue el Deployment.

---

### 5.2 Depuración de Falsos Positivos en WAF (Exclusión de Reglas en ModSecurity)

Si el tráfico legítimo de los usuarios recibe HTTP `403 Forbidden` debido a una puntuación de anomalía (anomaly scoring) del WAF excesivamente estricta, realice una exclusión granular de reglas sin desactivar por completo el motor del WAF.

#### Paso 1: Analizar el audit log para identificar el ID de la regla desencadenante
Busque en `/var/log/nginx/modsec_audit.log` el ID de petición específico y localice el ID de la regla fallida:

```bash
$ grep -E "Access denied|id " /var/log/nginx/modsec_audit.log | tail -n 6
[tag "attack-sqli"] ModSecurity: Access denied with code 403 (phase 2). Match of "regex (?:union\s+select)" against "ARGS:query" required. [id "942190"]
```

#### Paso 2: Añadir la exclusión de regla en la configuración de ModSecurity
Vaya a `/etc/nginx/modsec/main.conf` e inyecte una regla orientada de tipo `SecRuleRemoveById` o exclusión de variable:

```apache
# Disable Rule 942190 exclusively for the specific endpoint path
SecRule REQUEST_URI "@beginsWith /api/v1/analytics/custom-query" \
    "id:100001,phase:1,nolog,pass,ctl:ruleRemoveById=942190"
```

#### Paso 3: Probar la configuración y recargar NGINX

```bash
$ nginx -t
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful

$ systemctl reload nginx
```

---

### 5.3 Diagnóstico de Fallos por Sistema de Archivos Raíz de Solo Lectura (`EROFS`)

Al configurar `readOnlyRootFilesystem: true` en los security contexts de contenedores, las aplicaciones que intenten escribir en directorios de logs temporales, archivos pid o cachés dinámicas fallarán con `EROFS (Read-only file system)`.

#### Paso 1: Capturar los logs de crash del contenedor

```bash
$ kubectl logs payment-processor-6d4b65559-x2b8n -n production-finance
2026/08/06 17:45:01 [CRITICAL] Failed to initialize application cache: open /app/cache/session.db: read-only file system
```

#### Paso 2: Resolución mediante volúmenes efímeros (`emptyDir`)
Identifique las ubicaciones de escritura faltantes y declare montajes efímeros `emptyDir` con alcance explícito en el manifiesto del Pod:

```yaml
volumeMounts:
  - name: app-cache
    mountPath: /app/cache
volumes:
  - name: app-cache
    emptyDir:
      medium: Memory
      sizeLimit: 64Mi
```

---

## 6. Referencias

* **Objetivos Oficiales del Linux Professional Institute (LPI)**:  
  [https://www.lpi.org/our-certifications/lpic-3-303-overview/](https://www.lpi.org/our-certifications/lpic-3-303-overview/)
* **Wiki de LPI — Objetivos Detallados de LPIC-3 Security (303-300)**:  
  [https://wiki.lpi.org/wiki/LPIC-3_303_Objectives_V3.0](https://wiki.lpi.org/wiki/LPIC-3_303_Objectives_V3.0)
* **Documentación Oficial del OWASP Core Rule Set (CRS)**:  
  [https://coreruleset.org/docs/](https://coreruleset.org/docs/)
* **Repositorio y Referencia del Conector de ModSecurity v3 para NGINX**:  
  [https://github.com/SpiderLabs/ModSecurity-nginx](https://github.com/SpiderLabs/ModSecurity-nginx)
* **Documentación del Kernel de Linux — Filtrado de Syscalls con Seccomp BPF**:  
  [https://www.kernel.org/doc/html/latest/userspace-api/seccomp_filter.html](https://www.kernel.org/doc/html/latest/userspace-api/seccomp_filter.html)
* **Documentación de Kubernetes — Pod Security Standards (Restricted Profile)**:  
  [https://kubernetes.io/docs/concepts/security/pod-security-standards/](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
* **NIST SP 800-190 — Guía de Seguridad para Contenedores de Aplicaciones**:  
  [https://csrc.nist.gov/publications/detail/sp/800-190/final](https://csrc.nist.gov/publications/detail/sp/800-190/final)