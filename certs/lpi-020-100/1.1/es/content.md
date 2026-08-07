# Guía Avanzada de Estudio para Producción: LPI Security Essentials (020-100) — Tema 1.1: Conceptos de Seguridad

**Certificación Objetivo:** LPI Security Essentials (Examen 020-100, Versión 1.0)  
**Código de Tema:** 1.1 Security Concepts (Goals, Roles, Actors, Risk Assessment & Ethical Behavior)  
**Peso del Examen:** 20  
**Audiencia Objetivo:** SREs Senior, Ingenieros de Seguridad y Arquitectos Principales de Plataforma  

---

## 1. Motivación y Problema Arquitectónico de Producción

### 1.1 La Crisis de Seguridad en Producción en la Infraestructura Cloud-Native
En las plataformas empresariales modernas, la seguridad ya no es un mecanismo aislado de defensa perimetral gestionado por un equipo de cumplimiento dedicado. Las arquitecturas cloud-native introducen enormes superficies de ataque dinámicas: cientos de Pods efímeros de Kubernetes, pipelines de CI/CD automatizados desplegando decenas de veces al día, conexiones mutual TLS de microservicio a microservicio y extensas cadenas de suministro de software de terceros.

Bajo este paradigma operativo, los conceptos clásicos de seguridad deben refactorizarse desde definiciones abstractas de cumplimiento hacia primitivas de ingeniería sólidas. Una sola imagen de contenedor no verificada o un token permisivo de ServiceAccount pueden comprometer un clúster entero. Los ingenieros de plataforma y los Site Reliability Engineers (SREs) deben hacer cumplir la seguridad sin degradar la velocidad de liberación, el rendimiento de las aplicaciones o la confiabilidad del sitio.

```
+-----------------------------------------------------------------------------------+
|                            PRODUCTION ATTACK SURFACE                              |
|                                                                                   |
|   +------------------+         +------------------+         +-----------------+   |
|   |  External Edge   | ------> | Kubernetes Ingress| ------> | Microservices   |   |
|   | (DDoS / Scanners)|         |  (TLS Termination) |         | (App Runtime)   |   |
|   +------------------+         +------------------+         +-----------------+   |
|                                                                      |            |
|                                                                      v            |
|   +------------------+         +------------------+         +-----------------+   |
|   | Insider Threat / | <------ |  CI/CD Pipeline  | <------ | Node OS Kernel  |   |
|   | Supply Chain     |         |  (Poisoned Image)|         | (eBPF / Audit)  |   |
|   +------------------+         +------------------+         +-----------------+   |
+-----------------------------------------------------------------------------------+
```

### 1.2 Objetivos Core de Seguridad y Mecánica Estructural

La ingeniería de seguridad se basa en cuatro garantías fundamentales conocidas colectivamente en sistemas de producción como el marco extendido **CIA+N**:

1. **Confidencialidad:** Garantizar que los datos en tránsito, en reposo y en uso sean inaccesibles para actores no autorizados.
   - *Implementación en producción:* Cifrado de sobre (AWS KMS / HashiCorp Vault), TLS 1.3 con Perfect Forward Secrecy (PFS), procesamiento efímero en memoria.
2. **Integridad:** Garantizar que la telemetría, el estado de la aplicación, los almacenes de datos y los binarios no hayan sido alterados de manera no autorizada o no detectada.
   - *Implementación en producción:* Firmas criptográficas (Sigstore/Cosign), sistemas de archivos de contenedores inmutables (`readOnlyRootFilesystem: true`), verificación criptográfica de checksum (fijación de digest SHA-256).
3. **Disponibilidad:** Garantizar que los sistemas informáticos, las rutas de red y los almacenes de datos permanezcan receptivos al tráfico legítimo a pesar de fallas en los nodos, ataques volumétricos o caídas de aplicaciones.
   - *Implementación en producción:* Mitigación de DDoS (Anycast, rate-limiting), distribuciones de topología tolerantes a fallas, autoescalado horizontal (HPA), circuit breaking, modos de servicio degradados elegantemente.
4. **No repudio:** Proporcionar prueba innegable del origen e integridad de una acción para que los actores no puedan negar la autoría de una solicitud de API, un commit de código o un cambio de infraestructura.
   - *Implementación en producción:* Commits de Git firmados criptográficamente (claves GPG/SSH), logs de auditoría inmutables append-only (AWS CloudTrail, logs de auditoría de Kubernetes almacenados en almacenamiento WORM).

### 1.3 Vectores de Ataque, Actores y Cálculo de Riesgo

La evaluación de riesgos en entornos SRE de producción se basa en puntuaciones cuantitativas. La fórmula de riesgo clásica utilizada en los modelos de gestión de riesgos de SRE se define como:

$$\text{Risk} = \text{Threat} \times \text{Vulnerability} \times \text{Impact}$$

Donde:
- **Threat (T):** La probabilidad de que un actor de amenaza aproveche una vulnerabilidad dada (con un rango de 0.0 a 1.0).
- **Vulnerability (V):** La severidad y accesibilidad de una falla de seguridad (por ejemplo, CVSS Base Score escalado de 0.0 a 1.0).
- **Impact (I):** El daño monetario u operativo cuantitativo incurrido por una brecha (medido en costo de tiempo de inactividad, penalizaciones de SLA, responsabilidad por exposición de datos).

#### Clasificaciones de Actores de Amenazas en Entornos Empresariales
- **Script Kiddies / Botnets Automatizadas:** Escaneos de alta frecuencia y baja sofisticación que buscan CVEs conocidos (por ejemplo, Log4Shell, endpoints no autenticados de Redis/Memcached).
- **Insiders Maliciosos:** Poseedores de acceso con altos privilegios que ejecutan escalada de privilegios o exfiltración no autorizada de datos. Mitigado por Menor Privilegio (Least Privilege), Separación de Funciones (Separation of Duties, SoD) y políticas de acceso Just-In-Time (JIT).
- **Amenazas Persistentes Avanzadas (APTs):** Sindicatos organizados de alta capacidad o respaldados por estados que ejecutan exploits de día cero, contaminación de la cadena de suministro y movimiento lateral silencioso.
- **Atacantes Automatizados de la Cadena de Suministro:** Typosquatting de dependencias en npm/PyPI, explotación de GitHub Actions no fijadas o compromiso de imágenes base de contenedores.

---

## 2. Comparativas Técnicas y Trade-offs Arquitectónicos

La selección de controles de seguridad requiere gestionar trade-offs explícitos de ingeniería. Endurecer un endpoint de aplicación a menudo introduce latencia o fricción para los desarrolladores; no endurecerlo introduce radios de explosión catastróficos.

### 2.1 Defensa Perimetral vs. Arquitectura Zero-Trust (ZTA)

| Métrica / Parámetro | Seguridad Perimetral Tradicional (Castle & Moat) | Arquitectura Cloud-Native Zero-Trust (ZTA) |
| :--- | :--- | :--- |
| **Modelo de Confianza** | Confianza implícita para todo el tráfico dentro de la red interna (VPC/LAN). | Verificación explícita para cada solicitud independientemente de la ubicación. |
| **Autenticación/Autorización** | Manejada en el VPN / Reverse Proxy perimetral una sola vez. | mTLS continuo + tokens de identidad SPIFFE/SPIRE de grano fino por llamada de servicio. |
| **Radio de Explosión** | Extremo. El compromiso de la red expone todos los servicios internos. | Mínimo. Políticas de red microsegmentadas aislan los contenedores comprometidos. |
| **Complejidad Operativa** | Baja a Moderada (firewalls centralizados/peering de VPC). | Alta (requiere service mesh, motor de rotación de PKI, motores de políticas). |
| **Impacto en Latencia** | Casi cero dentro de la red interna. | Sobrecarga a nivel de microsegundos por salto debido a handshakes mTLS y evaluación de políticas. |

### 2.2 Paradigmas de Control de Acceso: RBAC vs. ABAC

| Característica | Control de Acceso Basado en Roles (RBAC) | Control de Acceso Basado en Atributos (ABAC) |
| :--- | :--- | :--- |
| **Factores de Decisión** | Roles de usuario asignados estáticamente (por ejemplo, `developer`, `admin`). | Contexto dinámico (rol de usuario, dirección IP, postura del dispositivo, hora del día, etiqueta de clasificación). |
| **Granularidad de Política** | De grano grueso / Estática. | De grano fino / Hiperdinámica. |
| **Gestión a Escala** | Sufre de "Explosión de Roles" a medida que las reglas se escalan. | Lenguaje complejo de evaluación de políticas (por ejemplo, Rego, Cedar). |
| **Soporte Nativo en Kubernetes**| Nativo (`rbac.authorization.k8s.io/v1`). | Webhook externo requerido (OPA Gatekeeper / Kyverno / Custom Webhook). |

### 2.3 Puntuación de Gestión de Vulnerabilidades: CVSS v3.1 vs. Explotabilidad en Producción (EPSS)

```
        CVSS Base Score (Theoretical Severity: 0-10)
                            VS
        EPSS Probability (Real-world Exploit Likelihood: 0-100%)
```

- **CVSS (Common Vulnerability Scoring System):** Mide la *severidad técnica intrínseca* (por ejemplo, Vector de Ataque, Complejidad, Privilegios Requeridos, métricas de Impacto).
- **EPSS (Exploit Prediction Scoring System):** Predice la *probabilidad* de que una vulnerabilidad sea realmente explotada en el entorno real dentro de 30 días basándose en inteligencia de amenazas en tiempo real.
- **Trade-off en Producción:** Corregir únicamente por CVSS $\ge 9.0$ crea agotamiento operativo ("fatiga de alertas"). La política de SRE prioriza vulnerabilidades donde $\text{CVSS} \ge 7.0$ **Y** $\text{EPSS} > 0.10$ (10% de probabilidad de explotación en el entorno real).

---

## 3. Manifiestos y Configuraciones Completos y Sintácticamente Válidos

Los siguientes manifiestos demuestran la implementación a nivel de producción de controles de seguridad que respaldan la Confidencialidad, Integridad, No repudio y Disponibilidad.

### 3.1 Microsegmentación Estricta de Red: Kubernetes NetworkPolicy
Este manifiesto aplica el aislamiento de red Zero-Trust para una aplicación backend de producción. Deniega todo el tráfico predeterminado de ingress/egress y permite explícitamente solo el ingress autenticado desde la API Gateway en el puerto 8080 y egress hacia DNS (puerto 53) y Postgres (puerto 5432).

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: enforce-strict-backend-isolation
  namespace: production
  labels:
    tier: backend
    app.kubernetes.io/sec-zone: restricted
spec:
  podSelector:
    matchLabels:
      app: payment-processor
      tier: backend
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # Allow ingress strictly from pods labeled role=api-gateway on port 8080
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: production
          podSelector:
            matchLabels:
              role: api-gateway
      ports:
        - protocol: TCP
          port: 8080
  egress:
    # Allow egress strictly to CoreDNS for name resolution
    - to:
        - namespaceSelector: {}
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    # Allow egress strictly to managed PostgreSQL database instances
    - to:
        - ipBlock:
            cidr: 10.240.16.0/24
      ports:
        - protocol: TCP
          port: 5432
```

### 3.2 Inmutabilidad y Seguridad en Tiempo de Ejecución: PodSecurity Admission Standards
Este manifiesto exige la inmutabilidad absoluta del contenedor en tiempo de ejecución, prohibiendo la escalada de privilegios, bloqueando la ejecución como root, eliminando todas las capacidades de Linux y haciendo que el sistema de archivos raíz sea de solo lectura.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hardened-payment-service
  namespace: production
  labels:
    app: payment-processor
    sec.tier: critical
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
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: payment-app
          image: internal-registry.enterprise.io/finance/payment-processor:v2.4.1@sha256:d8e9f2a24c52b477bc2b9e69315d18d45e0d4dfef17bc9ef4a8ef7be12185c7f
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 10001
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
          ports:
            - containerPort: 8080
              name: http
          volumeMounts:
            - mountPath: /tmp
              name: ephemeral-tmp
      volumes:
        - name: ephemeral-tmp
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
```

### 3.3 Reglas de Auditoría del Sistema Linux: `/etc/audit/rules.d/audit.rules`
Para garantizar el no repudio y la trazabilidad forense en la infraestructura de hosts Linux, esta configuración del sistema monitorea la escalada de privilegios (`sudoers`), la ejecución de archivos binarios, la modificación no autorizada de configuraciones de seguridad y los eventos de autenticación de usuarios.

```ini
# Delete all existing audit rules
-D

# Set buffer size to handle high-throughput event spikes
-b 8192

# Set failure mode to silent panic (1 = printk, 2 = panic)
-f 1

# Monitor changes to system time and date
-a always,exit -F arch=b64 -S adjtimex -S settimeofday -S clock_settime -k time-change

# Monitor identity and user/group modifications
-w /etc/group -p wa -k identity-modification
-w /etc/passwd -p wa -k identity-modification
-w /etc/gshadow -p wa -k identity-modification
-w /etc/shadow -p wa -k identity-modification
-w /etc/security/opasswd -p wa -k identity-modification

# Monitor changes to network configuration
-w /etc/issue -p wa -k network-config
-w /etc/issue.net -p wa -k network-config
-w /etc/hosts -p wa -k network-config
-w /etc/sysconfig/network -p wa -k network-config

# Monitor privilege escalation mechanisms (Sudoers)
-w /etc/sudoers -p wa -k privilege-escalation
-w /etc/sudoers.d/ -p wa -k privilege-escalation

# Audit execution of privileged binaries (setuid / setgid)
-a always,exit -F arch=b64 -F euid=0 -F auid>=1000 -F auid!=4294967295 -S execve -k privilege-execution

# Lock the audit configuration to prevent runtime modification (requires reboot to change)
-e 2
```

---

## 4. Real CLI Commands and Expected Terminal Outputs

The following workflows execute real security validation commands, image scans, audit log searches, and forensic evidence gathering.

### 4.1 Vulnerability Scanning and Risk Classification with Trivy

Run an automated static vulnerability scan against a container image to assess CVE severity and EPSS ratings prior to deployment.

```bash
$ trivy image --severity HIGH,CRITICAL --format table internal-registry.enterprise.io/finance/payment-processor:v2.4.1
```

```text
2026-08-07T00:41:12.102Z	INFO	Vulnerability database is up to date
2026-08-07T00:41:13.489Z	INFO	Detected OS: alpine 3.18.2
2026-08-07T00:41:13.490Z	INFO	Detecting Alpine vulnerabilities...
2026-08-07T00:41:13.512Z	INFO	Number of language-specific files: 1
2026-08-07T00:41:13.512Z	INFO	Detecting Go vulnerabilities...

internal-registry.enterprise.io/finance/payment-processor:v2.4.1 (alpine 3.18.2)
=================================================================================
Total: 2 (HIGH: 1, CRITICAL: 1)

┌──────────────┬────────────────┬──────────┬──────────────┬───────────────────┬─────────────────────────┐
│   LIBRARY    │ VULNERABILITY  │ SEVERITY │ INSTALLED    │ FIXED VERSION     │          TITLE          │
├──────────────┼────────────────┼──────────┼──────────────┼───────────────────┼─────────────────────────┤
│ libcrypto3   │ CVE-2023-3817  │ HIGH     │ 3.1.1-r1     │ 3.1.1-r3          │ OpenSSL: excess time    │
│              │                │          │              │                   │ checking DH keys        │
│ openssl      │ CVE-2023-5363  │ CRITICAL │ 3.1.1-r1     │ 3.1.1-r3          │ OpenSSL: Incorrect key  │
│              │                │          │              │                   │ length processing       │
└──────────────┴────────────────┴──────────┴──────────────┴───────────────────┴─────────────────────────┘
```

### 4.2 Verifying Non-Repudiation with Linux `ausearch` and `auparse`

Query the Linux kernel audit subsystem to track unauthorized modifications to `/etc/sudoers` or execution of privileged commands by user accounts.

```bash
$ sudo ausearch -k privilege-escalation --start recent -i
```

```text
----
time->Fri Aug  7 00:32:10 2026
type=PROCTITLE msg=audit(1786081930.412:9481): proctitle=56492F6574632F7375646F657273
type=PATH msg=audit(1786081930.412:9481): item=1 name="/etc/sudoers" inode=131089 dev=08:01 mode=0100440 ouid=0 ogid=0 rdev=00:00 nametype=NORMAL cap_fp=0 cap_fi=0 cap_fe=0 cap_fver=0
type=PATH msg=audit(1786081930.412:9481): item=0 name="/etc/" inode=131073 dev=08:01 mode=040755 ouid=0 ogid=0 rdev=00:00 nametype=PARENT cap_fp=0 cap_fi=0 cap_fe=0 cap_fver=0
type=SYSCALL msg=audit(1786081930.412:9481): arch=x86_64 syscall=openat success=yes exit=3 a0=ffffff9c a1=7ffd281a8b90 a2=241 a3=1b6 items=2 ppid=1420 pid=2819 auid=sysadmin uid=0 gid=0 euid=0 suid=0 fsuid=0 egid=0 sgid=0 fsgid=0 tty=pts1 ses=4 comm="vim" exe="/usr/bin/vim" key="privilege-escalation"
```

### 4.3 Auditing Active Network Exposure via `nmap` and `ss`

Audit a running host to discover open sockets, unexpected listening services, and active network connections violating perimeter boundaries.

```bash
$ sudo ss -tulpn
```

```text
Netid  State   Recv-Q  Send-Q     Local Address:Port      Peer Address:Port  Process                                                                         
tcp    LISTEN  0       4096             0.0.0.0:22             0.0.0.0:*      users:(("sshd",pid=892,fd=3))                                                   
tcp    LISTEN  0       511              0.0.0.0:8080           0.0.0.0:*      users:(("payment-app",pid=4102,fd=7))                                           
tcp    LISTEN  0       4096       127.0.0.53%lo:53             0.0.0.0:*      users:(("systemd-resolve",pid=621,fd=13))                                       
tcp    LISTEN  0       128            127.0.0.1:6379           0.0.0.0:*      users:(("redis-server",pid=1120,fd=6))                                          
```

Perform an authenticated TCP SYN stealth scan against a target node to locate rogue ports:

```bash
$ nmap -sS -p 1-10000 -T4 -n 10.240.0.45
```

```text
Starting Nmap 7.94 ( https://nmap.org ) at 2026-08-07 00:43 UTC
Nmap scan report for 10.240.0.45
Host is up (0.00042s latency).
Not shown: 9997 closed tcp ports (reset)
PORT     STATE SERVICE
22/tcp   open  ssh
8080/tcp open  http-proxy
6379/tcp open  redis

Nmap done: 1 IP address (1 host up) scanned in 0.84 seconds
```

---

## 5. Guía de Verificación y Diagnóstico de Fallas

Cuando los controles de seguridad fallan o desencadenan incidentes, los SREs deben seguir una metodología de diagnóstico sistemática para rastrear las causas raíz sin destruir evidencia forense.

### 5.1 Diagrama de Flujo de Diagnóstico de Incidentes de Seguridad de SRE

```
                 +--------------------------------------+
                 |      Security Alert / Incident       |
                 +--------------------------------------+
                                    |
                                    v
                 +--------------------------------------+
                 |  1. Containment & Pod Isolation      |
                 |     (Apply Isolation NetworkPolicy)  |
                 +--------------------------------------+
                                    |
                                    v
                 +--------------------------------------+
                 |  2. Memory & Volatile State Capture  |
                 |     (Dump process tree & open files) |
                 +--------------------------------------+
                                    |
                                    v
                 +--------------------------------------+
                 |  3. Log & Telemetry Forensic Audit   |
                 |     (Inspect auditd / k8s audit logs)|
                 +--------------------------------------+
                                    |
                                    v
                 +--------------------------------------+
                 |  4. Root Cause Analysis & Mitigation |
                 |     (Revoke creds, patch CVE, redeploy)|
                 +--------------------------------------+
```

### 5.2 Matriz de Resolución de Problemas de SRE: Modos de Falla Comunes

| Síntoma / Alerta | Hipótesis de Causa Raíz | Comando de Verificación | Acción de Remediación |
| :--- | :--- | :--- | :--- |
| **`ErrImagePull` o `ImagePullBackOff`** | La imagen del contenedor falló la verificación de firma criptográfica o la puerta de umbral de vulnerabilidad. | `cosign verify --key cosign.pub $IMAGE` | Volver a firmar artefactos de pipeline confiables o parchear dependencias con fallas. |
| **Pod cayendo con `OOMKilled` o `CrashLoopBackOff`** | Límite de memoria alcanzado debido a `readOnlyRootFilesystem: true` escribiendo en un directorio prohibido. | `kubectl logs $POD -p \| grep "Read-only file system"` | Montar volúmenes efímeros `emptyDir` temporales en rutas de escritura específicas (por ejemplo, `/tmp`). |
| **Llamada a API con `403 Forbidden` desde ServiceAccount** | Desviación de permisos RBAC o `ClusterRoleBinding` faltante. | `kubectl auth can-i create pods --as=system:serviceaccount:prod:my-sa` | Aplicar manifiesto RBAC corregido usando el principio de menor privilegio. |
| **Pico de tráfico volumétrico en Pod backend** | NetworkPolicy de Ingress faltante; el tráfico directo nodo a nodo evitó el control perimetral. | `kubectl get netpol -n production` | Desplegar una `NetworkPolicy` estricta de denegación predeterminada para todo el namespace. |

### 5.3 Forensia de Incidentes Paso a Paso: Investigando la Ejecución de Procesos Sospechosos

Si una alerta en tiempo de ejecución (por ejemplo, Falco) marca la ejecución de un binario no esperado (`/tmp/malware`) dentro de un contenedor en ejecución, ejecute los siguientes pasos:

#### Paso 1: Aislar Inmediatamente la Red del Pod
Aplique una política de red de cuarentena de emergencia dirigida al Pod comprometido:

```bash
$ kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: quarantine-compromised-pod
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: payment-processor
      status: compromised
  policyTypes:
    - Ingress
    - Egress
EOF
```

#### Paso 2: Extraer la Memoria del Proceso y los Sockets de Red
No termine el Pod inmediatamente; terminar el Pod borra evidencia forense volátil almacenada en los pseudosistemas de archivos de Linux (`/proc`).

```bash
# Obtain the container ID and process ID (PID) on the host node
$ CONTAINER_ID=$(docker ps --filter "label=io.kubernetes.pod.name=hardened-payment-service-75b5b9c564-x9q8z" -q)
$ HOST_PID=$(docker inspect --format '{{ .State.Pid }}' $CONTAINER_ID)

# Inspect open file descriptors and active sockets of the suspect process
$ sudo ls -la /proc/$HOST_PID/fd
$ sudo cat /proc/$HOST_PID/cmdline
```

#### Paso 3: Inspeccionar los Logs de Auditoría del Kernel en Busca de Ejecución de Binarios
Obtenga el payload exacto de auditoría para identificar la identidad real del usuario (`auid`) y el ID del proceso padre (`ppid`).

```bash
$ sudo ausearch -p $HOST_PID --format raw | auparse -i
```

```text
type=SYSCALL msg=audit(08/07/2026 00:44:12.891:10421) : arch=x86_64 syscall=execve success=yes exit=0 a0=0x55d8f1e20a10 a1=0x55d8f1e20aa8 a2=0x55d8f1e20b18 items=2 ppid=4102 pid=4892 auid=sysadmin uid=10001 gid=10001 euid=10001 exe=/tmp/miner key=privilege-execution
```

#### Paso 4: Remediar y Evictar
Revoque tokens de ServiceAccount expuestos, actualice imágenes base, rote credenciales de base de datos almacenadas en HashiCorp Vault y vuelva a desplegar la revisión del Deployment.

---

## 6. Referencias

- **Linux Professional Institute (LPI) Security Essentials Overview:**  
  [https://www.lpi.org/our-certifications/security-essentials-overview/](https://www.lpi.org/our-certifications/security-essentials-overview/)
- **LPI Security Essentials Objectives 020-100:**  
  [https://wiki.lpi.org/wiki/Security_Essentials_Objectives_V1.0](https://wiki.lpi.org/wiki/Security_Essentials_Objectives_V1.0)
- **NIST SP 800-53 Rev. 5 — Security and Privacy Controls for Information Systems:**  
  [https://csrc.nist.gov/publications/detail/sp/800-53/rev-5/final](https://csrc.nist.gov/publications/detail/sp/800-53/rev-5/final)
- **CNCF Financial & Security SIG — Cloud Native Security Paper:**  
  [https://github.com/cncf/tag-security/blob/main/security-whitepaper/v2/cloud-native-security-whitepaper-v2.md](https://github.com/cncf/tag-security/blob/main/security-whitepaper/v2/cloud-native-security-whitepaper-v2.md)
- **FIRST Common Vulnerability Scoring System (CVSS) v3.1 Specification:**  
  [https://www.first.org/cvss/v3.1/specification-document](https://www.first.org/cvss/v3.1/specification-document)
- **FIRST Exploit Prediction Scoring System (EPSS):**  
  [https://www.first.org/epss/](https://www.first.org/epss/)
- **Kubernetes Documentation — Pod Security Standards & Network Policies:**  
  [https://kubernetes.io/docs/concepts/security/pod-security-standards/](https://kubernetes.io/docs/concepts/security/pod-security-standards/)  
  [https://kubernetes.io/docs/concepts/services-networking/network-policies/](https://kubernetes.io/docs/concepts/services-networking/network-policies/)