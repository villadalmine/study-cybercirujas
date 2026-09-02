# CKS 6.2 — Detectar amenazas dentro de la infraestructura física, aplicaciones, redes, datos, usuarios y cargas de trabajo

> **Dominio:** Monitoring, Logging and Runtime Security
> **Currículo:** CKS v1.34 · **Peso relativo:** 4
> **Prerrequisitos:** 6.1 (análisis de comportamiento / visibilidad de syscalls), 2.x (RBAC, auditoría), 4.x (seccomp/AppArmor)

---

## 1. Motivación: el problema arquitectónico que la detección resuelve realmente

Cada control que construiste en los dominios 1–5 es una **precondición**, no una garantía. Los admission controllers rechazan manifiestos malos en `t=0`; los escáneres de imágenes afirman hechos sobre una capa en tiempo de build; las NetworkPolicies restringen una topología. Ninguno observa qué hizo *realmente* el proceso en `t=+3h`, cuando un contenedor legítimo, firmado, no privilegiado y PSA-`restricted` parseó un PDF hostil y lanzó `/bin/sh`.

El modo de fallo en producción es específico y repetible:

```
Build-time posture:  image scanned clean          → CVE-2026-XXXX published 4 days later
Admission posture:   runAsNonRoot, no privileges  → CAP_NET_BIND_SERVICE not needed for reverse shell
Network posture:     NetworkPolicy egress to      → attacker exfiltrates over the *allowed* DNS path
                     10.0.0.0/8 + 443/tcp             and the *allowed* 443 to a CDN-fronted C2
RBAC posture:        SA can only get configmaps   → the SA token is stolen and replayed from a
                                                     laptop in another AS; RBAC says "authorised"
```

Cada uno de esos casos es un **compromiso que cumple con la política**. La prevención es un filtro sobre la *intención declarada*; la detección es un filtro sobre el *comportamiento observado*. Necesitás ambos, y el examen CKS evalúa el segundo porque es la capa que la mayoría de los equipos se saltea.

La restricción arquitectónica que hace esto difícil específicamente en Kubernetes:

| Restricción | Consecuencia para el diseño de detección |
|---|---|
| Los contenedores comparten un único kernel | Un solo sensor a nivel de nodo ve *todos* los tenants — bueno para la cobertura, catastrófico para el radio de impacto si el sensor mismo se ve comprometido (corre privilegiado). |
| Los Pods son efímeros (vida p50 de minutos) | El análisis forense posterior sobre el pod suele ser imposible. La telemetría debe **transmitirse fuera del nodo** antes de que el pod muera. |
| La identidad está estratificada (nodo → SA → usuario → workload) | Un evento sin enriquecimiento de namespace/pod/imagen es casi inútil. Los flujos crudos de syscalls deben cruzarse con metadatos de CRI + API server *en el momento de la captura*. |
| El control plane es una API, no una shell | El 80 % de la actividad de amenaza a nivel "usuario" es una petición HTTPS autenticada. Solo el **audit log del API server** la ve; ningún sensor de nodo lo hace. |
| Los nodos son ganado, las imágenes están fijadas | La integridad de firmware/arranque del nodo es completamente invisible para Kubernetes. Requiere telemetría TPM/IMA/Secure Boot desde por debajo del SO. |

### El contrato de detección

Diseñá cada control de detección contra cuatro propiedades medibles, y escribilas en el SLO:

| Propiedad | Definición | Objetivo realista en producción |
|---|---|---|
| **Cobertura** | Fracción de las técnicas ATT&CK relevantes que producen al menos una señal | ≥ 70 % de ATT&CK for Containers |
| **Fidelidad** | Verdaderos positivos ÷ total de alertas para el conjunto de reglas ajustado | ≥ 0,6 para `Critical`+ |
| **Latencia (MTTD)** | Evento → alerta visible para el analista | < 60 s local al nodo, < 5 min en el SIEM |
| **Integridad** | ¿Puede el adversario borrar o falsificar la señal? | Append-only, fuera del nodo en menos de 10 s |

Una regla que dispara con 5 % de precisión es *peor que nada*: entrena al on-call a hacer `Ack` por reflejo. Ajustá sin piedad.

---

## 2. Modelo de amenazas: los seis planos de detección

El ítem del currículo nombra seis superficies. No son arbitrarias — cada una se corresponde con una **fuente de señal** distinta, y ninguna fuente puede sustituir a otra.

```
                        ┌─────────────────────────────────────────────┐
   USERS ───────────────►  kube-apiserver audit log  (HTTP/API plane) │
   (kubectl, CI, SA)    │  → who did what, to which object, from where│
                        └────────────────────┬────────────────────────┘
                                             │
                        ┌────────────────────▼────────────────────────┐
   WORKLOADS / APPS ────►  syscall telemetry  (Falco / Tetragon /     │
   (exec, file, proc)   │  Tracee — kmod or eBPF)                     │
                        └────────────────────┬────────────────────────┘
                                             │
                        ┌────────────────────▼────────────────────────┐
   NETWORK ─────────────►  flow + DNS telemetry (Hubble / eBPF socket │
   (L3/L4/L7, DNS)      │  events / NetworkPolicy denies)             │
                        └────────────────────┬────────────────────────┘
                                             │
                        ┌────────────────────▼────────────────────────┐
   DATA ────────────────►  file-open telemetry + audit on Secrets     │
   (secrets, PV, etcd)  │  (Falco fd.name / Tetragon security_file_*) │
                        └────────────────────┬────────────────────────┘
                                             │
                        ┌────────────────────▼────────────────────────┐
   OS / KERNEL ─────────►  auditd, seccomp SCMP_ACT_LOG, AppArmor     │
   (node processes)     │  complain-mode, kernel taint                │
                        └────────────────────┬────────────────────────┘
                                             │
                        ┌────────────────────▼────────────────────────┐
   PHYSICAL INFRA ──────►  Secure Boot, TPM PCRs, IMA measurement log,│
   (firmware, disk, BMC)│  FIM (AIDE), BMC/IPMI logs                  │
                        └─────────────────────────────────────────────┘
```

### 2.1 Correspondencia con MITRE ATT&CK for Containers

Esta es la matriz de cobertura que deberías poder reproducir de memoria; determina qué reglas escribís.

| ID ATT&CK | Técnica | Mejor plano | Señal concreta |
|---|---|---|---|
| T1610 | Deploy Container | Usuarios (audit) | `create` sobre `pods`, `privileged:true`, `hostPID` |
| T1611 | Escape to Host | Workloads | `nsenter`, apertura de `/proc/*/root`, `unshare`, syscall `mount` dentro del contenedor |
| T1613 | Container & Resource Discovery | Usuarios + Workloads | ráfaga de `list` sobre `pods` en varios namespaces; `crictl`/`docker` en el contenedor |
| T1552.001 | Credentials in Files | Datos | apertura de `/var/run/secrets/kubernetes.io/serviceaccount/token` por un proceso que no es el de la app |
| T1552.007 | Container API | Red | conexión a `10.96.0.1:443` o a `unix:///run/containerd/...` |
| T1078 | Valid Accounts | Usuarios | token de SA usado desde una `sourceIP` fuera del CIDR del clúster |
| T1525 | Implant Internal Image | Cadena de suministro + Usuarios | `create` sobre `pods` con un digest sin firmar |
| T1496 | Resource Hijacking | Workloads + Red | proceso de la clase `xmrig`, resoluciones DNS de stratum, CPU sostenida |
| T1070.004 | Indicator Removal (borrado de archivos) | Workloads | `unlink` de `/var/log/*` dentro del contenedor |
| T1543 | Create/Modify System Process | SO | escritura en `/etc/systemd/system`, `/etc/cron.d` |
| T1078.001 | Default Accounts | Usuarios | `system:anonymous` / `system:unauthenticated` en el audit log |

---

## 3. Plano: infraestructura física e integridad del nodo

Kubernetes tiene **cero** visibilidad aquí. Si el firmware miente, todas las capas por encima mienten. En clústeres bare-metal (y en el modelo mental de "worker node" del CKS) afirmás la integridad con tres mecanismos independientes.

### 3.1 Verificar la cadena de arranque

```bash
$ mokutil --sb-state
SecureBoot enabled

$ sudo dmesg | grep -iE 'secure boot|lockdown'
[    0.000000] secureboot: Secure boot enabled
[    0.000000] Kernel is locked down from EFI Secure Boot mode; see man kernel_lockdown.7

$ sudo tpm2_pcrread sha256:0,1,4,7,10
  sha256:
    0 : 0x3D458CFE55CC03EA1F443F1562BEEC8DF51C75E14A9FCF9A7234A13F198E7969
    1 : 0xE6E1B3A5C0F1A0B0C4A2B7F0C1D2E3F40506A7B8C9DAEBFC0D1E2F3041526374
    4 : 0x9B2D6C3A1F4E5D8C7B0A9E8D7C6B5A4938271605F4E3D2C1B0A99887766554433
    7 : 0x65CAF2C4B1E9A0D3F5768899AABBCCDDEEFF00112233445566778899AABBCCDD
   10 : 0x0A1B2C3D4E5F60718293A4B5C6D7E8F9A0B1C2D3E4F50617

# PCR 0/7 pin firmware + Secure Boot policy. A change here between reboots is a
# firmware/bootloader event, not a Kubernetes event. Alert on it.
```

### 3.2 Medición de archivos a nivel de kernel (IMA)

IMA (Integrity Measurement Architecture) extiende el PCR 10 con un hash de cada binario ejecutado. Es el único mecanismo que detecta un **binario de kubelet reemplazado** antes de que se ejecute.

Parámetros de arranque (`/etc/default/grub` → `GRUB_CMDLINE_LINUX`):

```
ima=on ima_policy=tcb ima_appraise=log ima_template=ima-ng ima_hash=sha256 lsm=integrity,apparmor
```

```bash
$ sudo head -4 /sys/kernel/security/ima/ascii_runtime_measurements
10 8b1f2c9d0a7e5f3b41c60d92aa8f4e77b3c5d901 ima-ng sha256:3f2a55c1ce7f6d0a9b8e4c2d1f0a9b8e7c6d5f4a3b2c1d0e9f8a7b6c5d4e3f2a1 boot_aggregate
10 c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f7 ima-ng sha256:9a8b7c6d5e4f30211f2e3d4c5b6a798877665544332211ffeeddccbbaa998877 /usr/lib/systemd/systemd
10 1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d ima-ng sha256:0011223344556677889900aabbccddeeff112233445566778899aabbccddeeff /usr/bin/containerd
10 f0e1d2c3b4a5968778695a4b3c2d1e0f9a8b7c6d ima-ng sha256:aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899 /usr/bin/kubelet

# Ship this list off-node. Diff it against a golden manifest per node image version.
$ sudo awk '{print $5, $6}' /sys/kernel/security/ima/ascii_runtime_measurements \
    | sort -u > /var/lib/node-attest/measurements.$(uname -r).txt
```

### 3.3 File Integrity Monitoring sobre la superficie del control plane

Los cinco directorios que importan en cualquier nodo de Kubernetes:

```
/etc/kubernetes/manifests/   ← static pod injection = instant cluster-admin
/etc/kubernetes/pki/         ← CA keys = forge any identity
/var/lib/kubelet/            ← kubelet config, seccomp profiles, SA token cache
/etc/containerd/ or /etc/crio/ ← runtime config, insecure registries, runtime class
/usr/bin/{kubelet,kubectl,containerd,runc}  ← binary replacement
```

**`/etc/aide/aide.conf.d/99-kubernetes.conf`** (completo):

```
# AIDE rules for Kubernetes node integrity.
# Rule atoms: p=perms u=uid g=gid s=size m=mtime c=ctime i=inode
#             sha256=content hash  ftype=file type  selinux/xattrs

K8S_STRICT   = p+u+g+s+m+c+i+ftype+sha256+xattrs
K8S_CONTENT  = p+u+g+ftype+sha256
K8S_GROWING  = p+u+g+ftype+S           # S = allow size to grow only (logs)

# --- Control plane, the highest-value target -------------------------------
/etc/kubernetes/manifests        K8S_STRICT
/etc/kubernetes/pki              K8S_STRICT
/etc/kubernetes/admin.conf       K8S_STRICT
/etc/kubernetes/kubelet.conf     K8S_STRICT

# --- Node runtime ----------------------------------------------------------
/var/lib/kubelet/config.yaml     K8S_STRICT
/var/lib/kubelet/seccomp         K8S_CONTENT
/etc/containerd/config.toml      K8S_STRICT
/etc/crictl.yaml                 K8S_STRICT

# --- Binaries --------------------------------------------------------------
/usr/bin/kubelet                 K8S_STRICT
/usr/bin/kubectl                 K8S_STRICT
/usr/bin/containerd              K8S_STRICT
/usr/bin/containerd-shim-runc-v2 K8S_STRICT
/usr/bin/runc                    K8S_STRICT

# --- Host persistence vectors ---------------------------------------------
/etc/cron.d                      K8S_STRICT
/etc/cron.daily                  K8S_STRICT
/etc/systemd/system              K8S_STRICT
/etc/ld.so.preload               K8S_STRICT
/root/.ssh                       K8S_STRICT
/etc/sudoers.d                   K8S_STRICT

# --- Explicit exclusions: high-churn paths that would drown the report -----
!/var/lib/kubelet/pods
!/var/lib/kubelet/plugins
!/var/lib/kubelet/device-plugins
!/var/lib/containerd
```

Unidad systemd + timer (completos, dejalos en `/etc/systemd/system/`):

```ini
# aide-check.service
[Unit]
Description=AIDE integrity check for Kubernetes node surface
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
# Exit 0=clean, 1=new files, 2=removed, 4=changed (bitmask, can combine)
ExecStart=/usr/bin/aide --config=/etc/aide/aide.conf --check
SuccessExitStatus=0
StandardOutput=journal
StandardError=journal
```

```ini
# aide-check.timer
[Unit]
Description=Run AIDE integrity check every 30 minutes

[Timer]
OnBootSec=10min
OnUnitActiveSec=30min
RandomizedDelaySec=180
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
$ sudo aide --config=/etc/aide/aide.conf --init
Start timestamp: 2026-08-05 09:14:02 +0000 (AIDE 0.18.6)
AIDE initialized database at /var/lib/aide/aide.db.new.gz
Number of entries:      1847

$ sudo mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
$ sudo systemctl enable --now aide-check.timer
Created symlink /etc/systemd/system/timers.target.wants/aide-check.timer → /etc/systemd/system/aide-check.timer

# Simulate the attack CKS cares about: static pod injection
$ sudo cp /tmp/evil-daemon.yaml /etc/kubernetes/manifests/kube-proxy-metrics.yaml

$ sudo aide --config=/etc/aide/aide.conf --check
Start timestamp: 2026-08-05 09:47:31 +0000 (AIDE 0.18.6)
AIDE found differences between database and filesystem!!

Summary:
  Total number of entries:      1848
  Added entries:                1
  Removed entries:              0
  Changed entries:              1

---------------------------------------------------
Added entries:
---------------------------------------------------
f+++++++++++++++++: /etc/kubernetes/manifests/kube-proxy-metrics.yaml

---------------------------------------------------
Changed entries:
---------------------------------------------------
d =....  mc.. . : /etc/kubernetes/manifests

---------------------------------------------------
Detailed information about changes:
---------------------------------------------------
Directory: /etc/kubernetes/manifests
  Mtime    : 2026-08-04 11:02:19 +0000        | 2026-08-05 09:47:12 +0000
  Ctime    : 2026-08-04 11:02:19 +0000        | 2026-08-05 09:47:12 +0000
```

> **Nota sobre el compromiso.** AIDE es un control *periódico*: el MTTD equivale en promedio a la mitad del intervalo del timer. Para `/etc/kubernetes/manifests` eso es demasiado lento — un static pod arranca a los ~20 s de que el archivo aterriza. Combiná AIDE (línea base de integridad, a nivel de nodo) con Falco/`fanotify` (basado en eventos, sub-segundo) sobre las mismas rutas. La sección 5 da la regla de Falco.

### 3.4 auditd: el log a prueba de manipulación del propio kernel

auditd sobrevive cuando el container runtime no lo hace, y registra el **loginuid** — el usuario interactivo original detrás de una cadena de `sudo`, que ningún sensor de contenedor puede recuperar.

**`/etc/audit/rules.d/50-kubernetes.rules`** (completo):

```
## Delete all existing rules and set a large backlog before loading ours.
-D
-b 32768
-f 1
--backlog_wait_time 60000

## ---- Immutable, high-value control-plane material -----------------------
-w /etc/kubernetes/pki/           -p wa   -k k8s_pki
-w /etc/kubernetes/manifests/     -p wa   -k k8s_static_pods
-w /etc/kubernetes/admin.conf     -p rwa  -k k8s_admin_kubeconfig
-w /var/lib/kubelet/config.yaml   -p wa   -k kubelet_config
-w /var/lib/kubelet/pki/          -p wa   -k kubelet_pki
-w /etc/containerd/config.toml    -p wa   -k runtime_config

## ---- Runtime binaries: record every invocation --------------------------
-w /usr/bin/kubectl               -p x    -k k8s_exec
-w /usr/bin/crictl                -p x    -k runtime_exec
-w /usr/bin/runc                  -p x    -k runtime_exec
-w /usr/bin/nsenter               -p x    -k container_escape
-w /usr/bin/unshare               -p x    -k container_escape

## ---- Host persistence & privilege escalation ---------------------------
-w /etc/ld.so.preload             -p wa   -k rootkit_preload
-w /etc/sudoers                   -p wa   -k privesc
-w /etc/sudoers.d/                -p wa   -k privesc
-w /etc/cron.d/                   -p wa   -k persistence
-w /etc/systemd/system/           -p wa   -k persistence
-w /root/.ssh/                    -p wa   -k persistence

## ---- Kernel module loading (rootkit / driver injection) ----------------
-a always,exit -F arch=b64 -S init_module -S finit_module -S delete_module -k module_load
-a always,exit -F arch=b32 -S init_module -S finit_module -S delete_module -k module_load

## ---- Container escape primitives ---------------------------------------
-a always,exit -F arch=b64 -S mount -S umount2 -F auid>=1000 -F auid!=unset -k mount_ops
-a always,exit -F arch=b64 -S setns -k namespace_switch
-a always,exit -F arch=b64 -S ptrace -F a0=0x4 -k ptrace_attach   # PTRACE_ATTACH

## ---- Make the ruleset immutable. Requires a reboot to change. ----------
## Put this LAST. -e 2 is what makes the audit trail trustworthy.
-e 2
```

```bash
$ sudo augenrules --load
$ sudo auditctl -s
enabled 2
failure 1
pid 1121
rate_limit 0
backlog_limit 32768
lost 0
backlog 0
backlog_wait_time 60000
backlog_wait_time_actual 0

# 'enabled 2' == immutable. Confirm the rules loaded:
$ sudo auditctl -l | head -5
-w /etc/kubernetes/pki -p wa -k k8s_pki
-w /etc/kubernetes/manifests -p wa -k k8s_static_pods
-w /etc/kubernetes/admin.conf -p rwa -k k8s_admin_kubeconfig
-w /var/lib/kubelet/config.yaml -p wa -k kubelet_config
-w /var/lib/kubelet/pki -p wa -k kubelet_pki

# Investigate: who read the CA key?
$ sudo ausearch -k k8s_pki -i --start recent
----
type=PROCTITLE msg=audit(08/05/2026 09:52:14.113:2231) : proctitle=cat /etc/kubernetes/pki/ca.key
type=PATH msg=audit(08/05/2026 09:52:14.113:2231) : item=0 name=/etc/kubernetes/pki/ca.key
  inode=262149 dev=fd:00 mode=file,600 ouid=root ogid=root rdev=00:00
  obj=system_u:object_r:cert_t:s0 nametype=NORMAL cap_fp=none cap_fi=none cap_fe=0 cap_fver=0
type=CWD msg=audit(08/05/2026 09:52:14.113:2231) : cwd=/home/deploy
type=SYSCALL msg=audit(08/05/2026 09:52:14.113:2231) : arch=x86_64 syscall=openat
  success=yes exit=3 a0=0xffffff9c a1=0x7ffd3c1a2b40 a2=O_RDONLY a3=0x0 items=1
  ppid=48210 pid=48344 auid=deploy uid=root gid=root euid=root suid=root fsuid=root
  egid=root sgid=root fsgid=root tty=pts0 ses=42 comm=cat exe=/usr/bin/cat
  subj=unconfined_u:unconfined_r:unconfined_t:s0-s0:c0.c1023 key=k8s_pki
```

El par `auid=deploy ses=42` es el oro forense: `uid=root` por el `sudo`, pero el **login UID es inmutable** e identifica a la persona.

```bash
$ sudo aureport -k --summary -i --start today

Key Summary Report
===========================
total  key
===========================
  312  k8s_exec
   47  k8s_pki
   19  runtime_exec
    6  container_escape
    2  module_load
```

---

## 4. Plano: usuarios — el audit log de Kubernetes

**Nada en el nodo ve `kubectl create clusterrolebinding`.** Es una petición HTTPS terminada por el API server. El audit log es la *única* fuente de verdad para el plano de usuarios, y está deshabilitado por defecto.

### 4.1 Niveles y etapas: el compromiso volumen/valor

| Nivel | Registra | Tamaño típico/día (clúster de 100 nodos) | Valor forense |
|---|---|---|---|
| `None` | nada | 0 | — (usalo para silenciar ruido) |
| `Metadata` | quién, cuándo, verbo, recurso, namespace, código de respuesta | ~1,5 GB | Responde *quién tocó qué*. Suficiente para el 80 % de las investigaciones. |
| `Request` | + cuerpo de la petición | ~12 GB | Muestra el manifiesto que se aplicó. Requerido para `create`/`update` sobre RBAC y Pods. |
| `RequestResponse` | + cuerpo de la respuesta | ~40 GB | Muestra los *valores* de los secrets en `get secrets`. **Casi nunca apropiado** — convierte el audit log en un almacén de secretos. |

| Etapa | Se emite cuando | ¿Usarla? |
|---|---|---|
| `RequestReceived` | la petición llega al handler | **Omitila globalmente.** Duplica el volumen y no aporta nada salvo la detección de peticiones que nunca se completaron. |
| `ResponseStarted` | se enviaron las cabeceras — solo long-running (`watch`) | Mantenela para `watch` sobre Secrets. |
| `ResponseComplete` | la respuesta terminó | **La que querés.** |
| `Panic` | el handler entró en pánico | Mantenela siempre; es gratis y rara. |

### 4.2 Política de auditoría de producción (completa)

**`/etc/kubernetes/audit/policy.yaml`**

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy

# Drop the RequestReceived stage globally: it doubles log volume and the
# ResponseComplete record is a strict superset for investigation purposes.
omitStages:
  - "RequestReceived"

# Strip managedFields from every logged body. On a busy cluster this is
# 30-60% of the bytes in a Request-level record and is never useful.
omitManagedFields: true

rules:
  # =========================================================================
  # 1. NOISE SUPPRESSION — must come first; the first matching rule wins.
  # =========================================================================

  # Kubelet and node-problem-detector heartbeats.
  - level: None
    users: ["system:kube-proxy"]
    verbs: ["watch"]
    resources:
      - group: ""
        resources: ["endpoints", "services", "services/status"]

  - level: None
    userGroups: ["system:nodes"]
    verbs: ["get", "list", "watch"]
    resources:
      - group: ""
        resources: ["nodes", "nodes/status"]

  # Leader-election churn: one write per second, per controller, forever.
  - level: None
    users:
      - "system:kube-controller-manager"
      - "system:kube-scheduler"
      - "system:serviceaccount:kube-system:endpoint-controller"
    verbs: ["get", "update"]
    namespaces: ["kube-system"]
    resources:
      - group: ""
        resources: ["endpoints"]
      - group: "coordination.k8s.io"
        resources: ["leases"]

  - level: None
    resources:
      - group: "coordination.k8s.io"
        resources: ["leases"]
    verbs: ["get", "update", "patch"]

  # Unauthenticated health/discovery endpoints — high volume, zero signal.
  - level: None
    nonResourceURLs:
      - "/healthz*"
      - "/livez*"
      - "/readyz*"
      - "/version"
      - "/metrics"
      - "/openapi/*"
      - "/apis"
      - "/apis/*"
      - "/api"
      - "/api/*"

  # =========================================================================
  # 2. CREDENTIAL ACCESS — T1552. Metadata ONLY: never log secret bodies.
  # =========================================================================
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps", "serviceaccounts/token"]
      - group: "authentication.k8s.io"
        resources: ["tokenreviews"]
    omitStages:
      - "RequestReceived"

  # =========================================================================
  # 3. INTERACTIVE ACCESS TO WORKLOADS — exec/attach/portforward is the
  #    single highest-fidelity "human in the data plane" signal there is.
  # =========================================================================
  - level: RequestResponse
    resources:
      - group: ""
        resources:
          - "pods/exec"
          - "pods/attach"
          - "pods/portforward"
          - "pods/proxy"
          - "services/proxy"
          - "nodes/proxy"

  # =========================================================================
  # 4. AUTHORISATION CHANGES — privilege escalation ground truth.
  # =========================================================================
  - level: RequestResponse
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
      - group: "certificates.k8s.io"
        resources: ["certificatesigningrequests", "certificatesigningrequests/approval"]
      - group: "admissionregistration.k8s.io"
        resources: ["validatingwebhookconfigurations", "mutatingwebhookconfigurations"]
      - group: "policy"
        resources: ["poddisruptionbudgets"]

  # =========================================================================
  # 5. WORKLOAD MUTATION — log the manifest so you can diff what was applied.
  # =========================================================================
  - level: Request
    verbs: ["create", "update", "patch", "delete", "deletecollection"]
    resources:
      - group: ""
        resources: ["pods", "persistentvolumes", "persistentvolumeclaims"]
      - group: "apps"
        resources: ["deployments", "daemonsets", "statefulsets", "replicasets"]
      - group: "batch"
        resources: ["jobs", "cronjobs"]
      - group: "networking.k8s.io"
        resources: ["networkpolicies", "ingresses"]

  # =========================================================================
  # 6. ANYTHING BY AN ANONYMOUS OR UNAUTHENTICATED PRINCIPAL.
  # =========================================================================
  - level: RequestResponse
    userGroups: ["system:unauthenticated"]

  # =========================================================================
  # 7. CATCH-ALL — Metadata for every remaining request.
  # =========================================================================
  - level: Metadata
    omitStages:
      - "RequestReceived"
```

### 4.3 Conectarlo al API server

Editá el manifiesto del static pod. **Toda ruta referenciada por un flag debe ser también un `volumeMount`** — esta es la causa #1 de un API server en CrashLoop en el examen.

**`/etc/kubernetes/manifests/kube-apiserver.yaml`** (fragmentos relevantes, completos):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: kube-apiserver
  namespace: kube-system
  labels:
    component: kube-apiserver
    tier: control-plane
spec:
  hostNetwork: true
  priorityClassName: system-node-critical
  containers:
    - name: kube-apiserver
      image: registry.k8s.io/kube-apiserver:v1.34.0
      command:
        - kube-apiserver
        - --advertise-address=10.0.1.10
        - --allow-privileged=true
        - --authorization-mode=Node,RBAC
        - --client-ca-file=/etc/kubernetes/pki/ca.crt
        - --enable-admission-plugins=NodeRestriction
        - --etcd-servers=https://127.0.0.1:2379
        - --service-account-issuer=https://kubernetes.default.svc.cluster.local
        - --service-cluster-ip-range=10.96.0.0/12
        # ---------- AUDIT ----------------------------------------------
        - --audit-policy-file=/etc/kubernetes/audit/policy.yaml
        - --audit-log-path=/var/log/kubernetes/audit/audit.log
        - --audit-log-format=json
        - --audit-log-maxage=30          # days of retention
        - --audit-log-maxbackup=10       # rotated files kept
        - --audit-log-maxsize=500        # MB before rotation
        - --audit-log-compress=true
        # Webhook backend: ship off-node so a node compromise cannot erase it.
        - --audit-webhook-config-file=/etc/kubernetes/audit/webhook.yaml
        - --audit-webhook-mode=batch
        - --audit-webhook-batch-max-size=400
        - --audit-webhook-batch-max-wait=5s
        - --audit-webhook-initial-backoff=10s
        - --audit-webhook-truncate-enabled=true
        - --audit-webhook-truncate-max-event-size=102400
        # ---------------------------------------------------------------
      volumeMounts:
        - name: k8s-certs
          mountPath: /etc/kubernetes/pki
          readOnly: true
        - name: audit-policy
          mountPath: /etc/kubernetes/audit
          readOnly: true
        - name: audit-logs
          mountPath: /var/log/kubernetes/audit
          readOnly: false          # MUST be writable
      livenessProbe:
        httpGet:
          host: 10.0.1.10
          path: /livez
          port: 6443
          scheme: HTTPS
        initialDelaySeconds: 10
        periodSeconds: 10
        timeoutSeconds: 15
        failureThreshold: 8
  volumes:
    - name: k8s-certs
      hostPath:
        path: /etc/kubernetes/pki
        type: DirectoryOrCreate
    - name: audit-policy
      hostPath:
        path: /etc/kubernetes/audit
        type: DirectoryOrCreate
    - name: audit-logs
      hostPath:
        path: /var/log/kubernetes/audit
        type: DirectoryOrCreate
```

**`/etc/kubernetes/audit/webhook.yaml`** — un kubeconfig estándar; `clusters[0].cluster.server` es el collector:

```yaml
apiVersion: v1
kind: Config
clusters:
  - name: audit-sink
    cluster:
      server: https://audit-collector.security.svc.cluster.local:8443/v1/audit
      certificate-authority: /etc/kubernetes/pki/ca.crt
contexts:
  - name: audit-sink-context
    context:
      cluster: audit-sink
      user: kube-apiserver-audit
current-context: audit-sink-context
users:
  - name: kube-apiserver-audit
    user:
      client-certificate: /etc/kubernetes/pki/apiserver-audit-client.crt
      client-key: /etc/kubernetes/pki/apiserver-audit-client.key
```

> **Modo de fallo.** `--audit-webhook-mode=blocking` hace que *cada petición a la API* espere al collector. Si el collector está dentro del clúster y el clúster está degradado, bloqueás el control plane en un deadlock. Usá `batch` en producción; usá `blocking-strict` solo cuando un regulador exija que ninguna petición avance sin auditar, y en ese caso alojá el collector **fuera** del clúster.

### 4.4 Cacería en el audit log

```bash
$ AUDIT=/var/log/kubernetes/audit/audit.log

# --- 1. Every interactive shell into a pod, ever ---------------------------
$ jq -r 'select(.objectRef.subresource=="exec")
         | [.requestReceivedTimestamp, .user.username, .sourceIPs[0],
            .objectRef.namespace + "/" + .objectRef.name,
            (.requestURI | split("?")[1] // "-")]
         | @tsv' "$AUDIT" | column -t -s$'\t'

2026-08-05T09:12:44.881Z  kubernetes-admin  10.0.1.10     kube-system/etcd-cp1        command=sh&container=etcd&stdin=true&tty=true
2026-08-05T10:41:07.220Z  ci-deployer       203.0.113.77  payments/api-6d4f8b9c-2xk4z command=%2Fbin%2Fbash&stdin=true&tty=true

# ci-deployer, a CI service account, opened an interactive TTY from a public
# IP. That is the alert. CI does not need a TTY.

# --- 2. Secret reads by non-system principals ------------------------------
$ jq -r 'select(.objectRef.resource=="secrets")
         | select(.verb=="get" or .verb=="list")
         | select(.user.username | startswith("system:") | not)
         | [.requestReceivedTimestamp, .user.username,
            .objectRef.namespace, (.objectRef.name // "LIST-ALL"),
            .sourceIPs[0], (.annotations["authorization.k8s.io/decision"] // "-")]
         | @tsv' "$AUDIT" | column -t -s$'\t'

2026-08-05T10:44:19.003Z  ci-deployer  payments  LIST-ALL   203.0.113.77  allow
2026-08-05T10:44:19.512Z  ci-deployer  default   LIST-ALL   203.0.113.77  allow
2026-08-05T10:44:20.118Z  ci-deployer  kube-system LIST-ALL 203.0.113.77  allow

# Namespace-walking a LIST on secrets in 1.1 s == T1613 + T1552.007.

# --- 3. RBAC escalation attempts, allowed AND denied ------------------------
$ jq -r 'select(.objectRef.apiGroup=="rbac.authorization.k8s.io")
         | select(.verb=="create" or .verb=="update" or .verb=="patch")
         | [.requestReceivedTimestamp, .user.username, .verb,
            .objectRef.resource, (.objectRef.name // "-"),
            .responseStatus.code,
            (.requestObject.roleRef.name // "-")]
         | @tsv' "$AUDIT" | column -t -s$'\t'

2026-08-05T10:45:02.771Z  ci-deployer  create  clusterrolebindings  ci-escalate  201  cluster-admin

# --- 4. Denied requests grouped by principal: reconnaissance fingerprint ----
$ jq -r 'select(.annotations["authorization.k8s.io/decision"]=="forbid")
         | .user.username' "$AUDIT" | sort | uniq -c | sort -rn | head

    412 system:serviceaccount:payments:api
     97 system:anonymous
     31 system:serviceaccount:default:default

# 412 forbids from one SA in one window = an implant enumerating its own
# permissions (equivalent to `kubectl auth can-i --list`).

# --- 5. Anything anonymous ---------------------------------------------------
$ jq -r 'select(.user.username=="system:anonymous")
         | [.requestReceivedTimestamp,.sourceIPs[0],.verb,.requestURI,
            .responseStatus.code] | @tsv' "$AUDIT" | head -3

2026-08-05T03:11:02.441Z  198.51.100.4  get   /api/v1/namespaces/default/pods   403
2026-08-05T03:11:02.998Z  198.51.100.4  get   /apis/rbac.authorization.k8s.io/v1/clusterroles  403
2026-08-05T03:11:03.512Z  198.51.100.4  post  /apis/authorization.k8s.io/v1/selfsubjectaccessreviews  201

# --- 6. Service-account tokens replayed from outside the cluster CIDR -------
$ jq -r 'select(.user.username | startswith("system:serviceaccount:"))
         | select(.sourceIPs[0] | test("^(10\\.|172\\.1[6-9]\\.|192\\.168\\.)") | not)
         | [.requestReceivedTimestamp,.user.username,.sourceIPs[0],.verb,.requestURI]
         | @tsv' "$AUDIT" | head

2026-08-05T10:41:00.004Z  system:serviceaccount:payments:api  203.0.113.77  get  /api/v1/namespaces/payments/secrets
```

La consulta 6 es la detección individual de mayor valor de todo el plano de usuarios. Un token de service account proyectado y acotado (bound) solo es válido dentro del pod; verlo presentado desde una IP externa significa que el token fue exfiltrado. Atalo a una alerta.

---

## 5. Plano: cargas de trabajo y aplicaciones — Falco en profundidad

### 5.1 Arquitectura

```
 ┌───────────────────────── userspace ──────────────────────────┐
 │ falco (rule engine)                                          │
 │   ├─ libsinsp   : state machine, fd table, thread table,     │
 │   │               container enrichment via CRI + k8s meta    │
 │   ├─ rule engine: condition eval → priority → output format  │
 │   └─ outputs    : stdout / file / syslog / gRPC / http / program
 └──────────────▲───────────────────────────────────────────────┘
                │ shared ring buffers (per-CPU, mmap'd)
 ┌──────────────┴───────────────── kernel ──────────────────────┐
 │ DRIVER  (exactly one of):                                    │
 │   modern_ebpf : CO-RE BPF, needs CONFIG_DEBUG_INFO_BTF, 5.8+ │
 │   ebpf        : legacy probe (falco-probe.o), 4.14+          │
 │   kmod        : falco.ko kernel module                       │
 │ Hooks: sys_enter / sys_exit tracepoints, sched_process_exit, │
 │        page_fault, signal_deliver                            │
 └──────────────────────────────────────────────────────────────┘
```

### 5.2 Comparación de drivers — esta decisión tiene consecuencias operativas reales

| | `modern_ebpf` (CO-RE) | `ebpf` (probe legacy) | `kmod` |
|---|---|---|---|
| Requisito de kernel | ≥ 5.8 **y** `CONFIG_DEBUG_INFO_BTF=y` | ≥ 4.14 | cualquiera soportado |
| Build/descarga en la instalación | ninguna — compilado dentro del binario | descargar/compilar `falco-probe.o` por kernel | descargar/compilar `falco.ko` por kernel |
| Comportamiento al actualizar el kernel | sigue funcionando | se rompe hasta compilar un probe nuevo | se rompe hasta compilar un módulo nuevo |
| Taint del nodo | ninguno | ninguno | `kmod` marca el kernel como tainted (`P`/`O`) |
| Radio de impacto de un crash | verificado por el verifier; a nivel de proceso | verificado por el verifier; a nivel de proceso | **kernel panic** |
| Overhead (pod con muchas syscalls) | ~2–4 % CPU | ~3–6 % | ~2–5 % |
| Funciona en GKE COS / Bottlerocket / Talos | sí | parcial | normalmente no |
| Recomendado | **opción por defecto** | solo kernels legacy | último recurso |

```bash
# Decide the driver empirically, not by folklore:
$ ls -l /sys/kernel/btf/vmlinux
-r--r--r--. 1 root root 6291456 Aug  5 08:02 /sys/kernel/btf/vmlinux
# → BTF present ⇒ modern_ebpf is available.

$ uname -r
6.8.0-45-generic

$ grep -E 'CONFIG_(BPF_JIT|DEBUG_INFO_BTF|BPF_LSM)=' /boot/config-$(uname -r)
CONFIG_BPF_JIT=y
CONFIG_DEBUG_INFO_BTF=y
CONFIG_BPF_LSM=y
```

### 5.3 `falco.yaml` — los ajustes que importan

**`/etc/falco/falco.yaml`** (anotado, valores de producción):

```yaml
# ---------------------------------------------------------------------------
# Rule sources, loaded in order. LATER FILES OVERRIDE EARLIER ONES.
# Never edit falco_rules.yaml: it is replaced on upgrade.
# ---------------------------------------------------------------------------
rules_files:
  - /etc/falco/falco_rules.yaml          # shipped, do not edit
  - /etc/falco/falco_rules.local.yaml    # your overrides of shipped rules
  - /etc/falco/rules.d                   # your own rules (directory)

# ---------------------------------------------------------------------------
# Engine / driver
# ---------------------------------------------------------------------------
engine:
  kind: modern_ebpf
  modern_ebpf:
    cpus_for_each_buffer: 2
    buf_size_preset: 4          # 1..10 → 1MB..512MB per buffer set
    drop_failed_exit: true      # discard failed syscalls: big volume cut

# ---------------------------------------------------------------------------
# Output plumbing
# ---------------------------------------------------------------------------
# Minimum priority a rule must have to be evaluated at all.
# Set to 'notice' in production; 'debug' floods the pipeline.
priority: notice

# Buffered output hides events when Falco is killed mid-flush. Turn it OFF.
buffered_outputs: false

# Rate-limit alerts so one runaway loop cannot DoS the collector.
outputs:
  rate: 1000                 # tokens refilled per second
  max_burst: 10000

json_output: true
json_include_output_property: true
json_include_tags_property: true

stdout_output:
  enabled: true

file_output:
  enabled: false
  keep_alive: false
  filename: /var/log/falco/events.log

syslog_output:
  enabled: false

http_output:
  enabled: true
  url: http://falcosidekick.falco.svc.cluster.local:2801/
  user_agent: "falcosecurity/falco"
  insecure: false
  echo: false

grpc:
  enabled: true
  bind_address: "unix:///run/falco/falco.sock"
  threadiness: 0

grpc_output:
  enabled: true

# ---------------------------------------------------------------------------
# Self-monitoring: Falco telling you it is blind. ALERT ON THESE.
# ---------------------------------------------------------------------------
syscall_event_drops:
  threshold: 0.1
  actions:
    - log
    - alert
  rate: 0.03333          # at most 1 drop alert every 30s
  max_burst: 1

metrics:
  enabled: true
  interval: 1h
  output_rule: true
  rules_counters_enabled: true
  resource_utilization_enabled: true
  kernel_event_counters_enabled: true
  libbpf_stats_enabled: true

# ---------------------------------------------------------------------------
# Plugins: container metadata + k8s pod/namespace enrichment.
# Without these, container.* and k8smeta.* fields are empty.
# ---------------------------------------------------------------------------
load_plugins:
  - container
  - k8smeta

plugins:
  - name: container
    library_path: libcontainer.so
    init_config:
      engines:
        cri:
          enabled: true
          sockets:
            - /run/containerd/containerd.sock
            - /run/crio/crio.sock
        docker:
          enabled: false
        podman:
          enabled: false

  - name: k8smeta
    library_path: libk8smeta.so
    init_config:
      collectorPort: 45000
      collectorHostname: k8s-metacollector.falco.svc.cluster.local
      nodeName: "${FALCO_K8S_NODE_NAME}"
```

### 5.4 Gramática de reglas — las partes que el CKS evalúa

```yaml
- rule: <unique name>            # duplicate name ⇒ later definition wins
  desc: <human description>
  condition: <sysdig filter expression>
  output: <printf-style with %field tokens>
  priority: <EMERGENCY|ALERT|CRITICAL|ERROR|WARNING|NOTICE|INFORMATIONAL|DEBUG>
  source: syscall                # or k8s_audit, or a plugin's event source
  tags: [container, mitre_execution, T1059]
  enabled: true
```

Construcciones de apoyo:

```yaml
- list: my_binaries
  items: [curl, wget, nc, ncat, socat]

- macro: my_container
  condition: (container.id != host)
```

Operadores: `=` `!=` `<` `<=` `>` `>=` `in` `intersects` `pmatch` `glob` `contains` `icontains` `bcontains` `startswith` `endswith` `exists`, combinados con `and` `or` `not` y paréntesis.

**Campos de alto valor (memorizalos):**

| Campo | Significado |
|---|---|
| `evt.type` | nombre de la syscall (`execve`, `open`, `openat`, `connect`, `setns`) |
| `evt.dir` | `>` = entrada, `<` = salida. Casi todas las reglas usan `evt.dir=<`. |
| `evt.time`, `evt.num` | timestamp / número monotónico de evento |
| `proc.name`, `proc.pname` | nombre del proceso / del proceso padre |
| `proc.cmdline`, `proc.exeline` | línea de comandos completa |
| `proc.pid`, `proc.ppid`, `proc.tty` | identificadores; `proc.tty != 0` ⇒ interactivo |
| `proc.aname[N]` | nombre del ancestro a profundidad N — derrota a `sh -c "sh -c ..."` |
| `fd.name` | ruta de archivo o tupla `ip:port` |
| `fd.sip`, `fd.sport`, `fd.cip` | IP/puerto del servidor, IP del cliente |
| `fd.directory`, `fd.filename` | ruta dividida |
| `user.name`, `user.uid`, `user.loginuid` | identidad; `loginuid=-1` ⇒ no interactivo |
| `container.id`, `container.name` | identidad del runtime |
| `container.image.repository`, `.tag`, `.digest` | identidad de la imagen |
| `container.privileged` | booleano |
| `k8smeta.ns.name`, `k8smeta.pod.name`, `k8smeta.pod.label[x]` | identidad de Kubernetes (requiere el plugin `k8smeta`) |

Macros incluidas de fábrica que conviene *reutilizar* en vez de reinventar: `container`, `spawned_process`, `open_write`, `open_read`, `outbound`, `inbound`, `never_true`, `proc_name_exists`; y listas incluidas `shell_binaries`, `known_binaries`, `sensitive_file_names`, `bin_dir`, `package_mgmt_binaries`.

### 5.5 Un conjunto de reglas propio completo

**`/etc/falco/rules.d/cks-threat-detection.yaml`**

```yaml
# =============================================================================
# CKS 6.2 — cross-plane threat detection ruleset
# Load AFTER falco_rules.yaml so overrides take effect.
# =============================================================================
- required_engine_version: 0.31.0

# -----------------------------------------------------------------------------
# Lists
# -----------------------------------------------------------------------------
- list: cks_shell_binaries
  items: [ash, bash, csh, ksh, sh, tcsh, zsh, dash, busybox]

- list: cks_pkg_mgmt_binaries
  items: [apt, apt-get, aptitude, dpkg, yum, dnf, rpm, apk, microdnf,
          pacman, zypper, pip, pip3, npm, gem, easy_install]

- list: cks_recon_binaries
  items: [nmap, masscan, zmap, nc, ncat, netcat, socat, tcpdump, tshark,
          hping3, arp-scan, dig, nslookup, host, whois, ss, netstat,
          ifconfig, ip, route, arp]

- list: cks_escape_binaries
  items: [nsenter, unshare, setns, chroot, pivot_root, docker, crictl,
          ctr, runc, kubectl, podman, nerdctl]

- list: cks_crypto_miner_binaries
  items: [xmrig, minerd, cpuminer, cgminer, bfgminer, ethminer, nbminer,
          t-rex, phoenixminer, xmr-stak, kdevtmpfsi, kinsing]

- list: cks_sensitive_host_paths
  items: ["/etc/shadow", "/etc/sudoers", "/etc/ssh/ssh_host_rsa_key",
          "/root/.ssh/authorized_keys", "/etc/kubernetes/pki",
          "/etc/kubernetes/admin.conf", "/var/lib/kubelet/pki",
          "/etc/ld.so.preload"]

- list: cks_trusted_image_registries
  items: ["registry.internal.corp", "registry.k8s.io", "ghcr.io/mycorp"]

- list: cks_system_namespaces
  items: [kube-system, kube-public, kube-node-lease, falco,
          monitoring, cilium-secrets]

# -----------------------------------------------------------------------------
# Macros
# -----------------------------------------------------------------------------
- macro: in_container
  condition: (container.id != host)

- macro: proc_started
  condition: (evt.type in (execve, execveat) and evt.dir=<)

- macro: file_opened_write
  condition: >
    (evt.type in (open, openat, openat2, creat) and evt.is_open_write=true
     and fd.typechar='f' and fd.num>=0)

- macro: file_opened_read
  condition: >
    (evt.type in (open, openat, openat2) and evt.is_open_read=true
     and fd.typechar='f' and fd.num>=0)

- macro: outbound_conn
  condition: >
    ((evt.type=connect and evt.dir=< and fd.l4proto in (tcp, udp))
     and (fd.typechar=4 or fd.typechar=6)
     and not fd.snet in ("127.0.0.0/8"))

- macro: cluster_internal_dest
  condition: >
    (fd.sip.name contains "cluster.local"
     or fd.snet in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
                    "100.64.0.0/10", "169.254.0.0/16"))

- macro: sa_token_path
  condition: (fd.name startswith "/var/run/secrets/kubernetes.io/serviceaccount")

# =============================================================================
# WORKLOAD PLANE
# =============================================================================

- rule: CKS Terminal Shell Spawned In Container
  desc: >
    An interactive shell was started inside a container. In an immutable,
    CI-deployed workload this never happens legitimately; it is either an
    operator bypassing change control or an attacker after RCE (T1059).
  condition: >
    proc_started
    and in_container
    and proc.name in (cks_shell_binaries)
    and (proc.tty != 0 or container.image.repository != "")
    and not proc.pname in (cks_shell_binaries)
    and not k8smeta.ns.name in (cks_system_namespaces)
  output: >
    Interactive shell spawned in container
    (evt_time=%evt.time user=%user.name uid=%user.uid loginuid=%user.loginuid
     shell=%proc.name parent=%proc.pname cmdline=%proc.cmdline tty=%proc.tty
     container_id=%container.id container_name=%container.name
     image=%container.image.repository:%container.image.tag
     ns=%k8smeta.ns.name pod=%k8smeta.pod.name)
  priority: WARNING
  tags: [container, shell, mitre_execution, T1059]
  source: syscall

- rule: CKS Package Management Executed In Container
  desc: >
    Installing software at runtime breaks image immutability and is the
    canonical persistence/tooling step after initial access (T1105).
  condition: >
    proc_started
    and in_container
    and proc.name in (cks_pkg_mgmt_binaries)
  output: >
    Package manager launched in container
    (evt_time=%evt.time container_id=%container.id user=%user.name
     command=%proc.cmdline image=%container.image.repository
     ns=%k8smeta.ns.name pod=%k8smeta.pod.name)
  priority: ERROR
  tags: [container, mitre_command_and_control, T1105]
  source: syscall

- rule: CKS Container Escape Tooling Executed
  desc: >
    Namespace-manipulation or runtime-control binaries executed inside a
    container. This is T1611 (Escape to Host) in its most direct form.
  condition: >
    proc_started
    and in_container
    and proc.name in (cks_escape_binaries)
  output: >
    Container escape tooling executed
    (evt_time=%evt.time proc=%proc.name cmdline=%proc.cmdline
     parent=%proc.pname user=%user.name uid=%user.uid
     container_id=%container.id image=%container.image.repository
     ns=%k8smeta.ns.name pod=%k8smeta.pod.name)
  priority: CRITICAL
  tags: [container, mitre_privilege_escalation, T1611]
  source: syscall

- rule: CKS Host Namespace Entered From Container
  desc: >
    setns() from inside a container onto a host namespace fd, or a read of
    another process's root via /proc/<pid>/root — a namespace break-out.
  condition: >
    in_container
    and ((evt.type=setns and evt.dir=<)
         or (file_opened_read and fd.name glob "/proc/*/root/*"))
  output: >
    Namespace escape attempt from container
    (evt_time=%evt.time evt=%evt.type target=%fd.name proc=%proc.name
     cmdline=%proc.cmdline container_id=%container.id
     ns=%k8smeta.ns.name pod=%k8smeta.pod.name)
  priority: CRITICAL
  tags: [container, mitre_privilege_escalation, T1611]
  source: syscall

- rule: CKS Cryptominer Process Started
  desc: Known cryptomining binary executed anywhere on the node (T1496).
  condition: >
    proc_started
    and (proc.name in (cks_crypto_miner_binaries)
         or proc.cmdline contains "stratum+tcp"
         or proc.cmdline contains "--donate-level"
         or proc.cmdline contains "nicehash")
  output: >
    Cryptomining activity detected
    (evt_time=%evt.time proc=%proc.name cmdline=%proc.cmdline
     container_id=%container.id image=%container.image.repository
     ns=%k8smeta.ns.name pod=%k8smeta.pod.name user=%user.name)
  priority: CRITICAL
  tags: [container, mitre_impact, T1496]
  source: syscall

- rule: CKS Untrusted Image Started
  desc: A container whose image does not come from an approved registry.
  condition: >
    proc_started
    and in_container
    and proc.vpid=1
    and not container.image.repository pmatch (cks_trusted_image_registries)
  output: >
    Container started from untrusted registry
    (evt_time=%evt.time image=%container.image.repository:%container.image.tag
     digest=%container.image.digest container_id=%container.id
     ns=%k8smeta.ns.name pod=%k8smeta.pod.name)
  priority: WARNING
  tags: [container, supply_chain, T1525]
  source: syscall

# =============================================================================
# DATA PLANE
# =============================================================================

- rule: CKS Service Account Token Read By Non App Process
  desc: >
    The projected SA token was read by a process other than the workload's
    own entrypoint. Precursor to token theft and off-cluster replay (T1552.001).
  condition: >
    file_opened_read
    and in_container
    and sa_token_path
    and not proc.name in (java, python3, python, node, ruby, dotnet, app,
                          kubectl, kube-proxy, coredns, cilium-agent)
  output: >
    Service account token read by unexpected process
    (evt_time=%evt.time file=%fd.name proc=%proc.name cmdline=%proc.cmdline
     parent=%proc.pname user=%user.name container_id=%container.id
     image=%container.image.repository ns=%k8smeta.ns.name pod=%k8smeta.pod.name)
  priority: CRITICAL
  tags: [container, secrets, mitre_credential_access, T1552.001]
  source: syscall

- rule: CKS Sensitive Host File Accessed From Container
  desc: >
    A container touched host credential material. Only reachable through a
    hostPath mount or an escape; either way it is an incident.
  condition: >
    (file_opened_read or file_opened_write)
    and in_container
    and fd.name pmatch (cks_sensitive_host_paths)
  output: >
    Sensitive host file accessed from container
    (evt_time=%evt.time file=%fd.name mode=%evt.arg.flags proc=%proc.name
     cmdline=%proc.cmdline container_id=%container.id
     image=%container.image.repository ns=%k8smeta.ns.name pod=%k8smeta.pod.name)
  priority: CRITICAL
  tags: [container, filesystem, mitre_credential_access, T1552.001]
  source: syscall

- rule: CKS Static Pod Manifest Directory Modified
  desc: >
    A write to /etc/kubernetes/manifests. The kubelet starts whatever lands
    there with no admission control, no RBAC, no PSA. Instant node takeover.
  condition: >
    file_opened_write
    and fd.directory startswith "/etc/kubernetes/manifests"
    and not proc.name in (kubeadm, kubelet)
  output: >
    Static pod manifest written outside kubeadm
    (evt_time=%evt.time file=%fd.name proc=%proc.name cmdline=%proc.cmdline
     user=%user.name loginuid=%user.loginuid container_id=%container.id)
  priority: CRITICAL
  tags: [host, k8s, mitre_persistence, T1543]
  source: syscall

- rule: CKS Kubernetes PKI Read
  desc: Any read of cluster CA private keys or the admin kubeconfig.
  condition: >
    file_opened_read
    and (fd.name startswith "/etc/kubernetes/pki"
         or fd.name = "/etc/kubernetes/admin.conf")
    and fd.name endswith ".key" or fd.name = "/etc/kubernetes/admin.conf"
    and not proc.name in (kube-apiserver, kube-controller-manager, etcd,
                          kubelet, kubeadm)
  output: >
    Kubernetes PKI material read by unexpected process
    (evt_time=%evt.time file=%fd.name proc=%proc.name cmdline=%proc.cmdline
     user=%user.name loginuid=%user.loginuid pid=%proc.pid ppid=%proc.ppid)
  priority: CRITICAL
  tags: [host, k8s, mitre_credential_access, T1552.001]
  source: syscall

# =============================================================================
# NETWORK PLANE
# =============================================================================

- rule: CKS Outbound Connection To Non Cluster Destination
  desc: >
    A workload initiated an egress connection outside RFC1918/cluster space.
    With a default-deny NetworkPolicy this should be impossible; if it fires,
    either the policy is missing or the workload found an allowed path (T1071).
  condition: >
    outbound_conn
    and in_container
    and not cluster_internal_dest
    and not fd.sport in (53)
    and not k8smeta.ns.name in (cks_system_namespaces)
  output: >
    Unexpected outbound connection from container
    (evt_time=%evt.time dest=%fd.sip:%fd.sport proto=%fd.l4proto
     proc=%proc.name cmdline=%proc.cmdline container_id=%container.id
     image=%container.image.repository ns=%k8smeta.ns.name pod=%k8smeta.pod.name)
  priority: WARNING
  tags: [network, mitre_command_and_control, T1071]
  source: syscall

- rule: CKS Contact To Kubernetes API From Unexpected Workload
  desc: >
    A pod that is not a controller talked to the API server ClusterIP.
    Legitimate for operators; suspicious for a web front end (T1552.007).
  condition: >
    outbound_conn
    and in_container
    and fd.sip = "10.96.0.1"
    and fd.sport = 443
    and not k8smeta.ns.name in (cks_system_namespaces)
    and not k8smeta.pod.label[security.corp/api-client] = "true"
  output: >
    Container contacted Kubernetes API server
    (evt_time=%evt.time dest=%fd.sip:%fd.sport proc=%proc.name
     cmdline=%proc.cmdline container_id=%container.id
     ns=%k8smeta.ns.name pod=%k8smeta.pod.name sa=%k8smeta.pod.label[app])
  priority: NOTICE
  tags: [network, k8s, mitre_discovery, T1552.007]
  source: syscall

- rule: CKS Network Reconnaissance Tooling In Container
  desc: Scanner or packet-capture tooling executed inside a container (T1046).
  condition: >
    proc_started
    and in_container
    and proc.name in (cks_recon_binaries)
    and not k8smeta.ns.name in (cks_system_namespaces)
  output: >
    Network recon tool executed in container
    (evt_time=%evt.time proc=%proc.name cmdline=%proc.cmdline
     parent=%proc.pname container_id=%container.id
     image=%container.image.repository ns=%k8smeta.ns.name pod=%k8smeta.pod.name)
  priority: WARNING
  tags: [network, container, mitre_discovery, T1046]
  source: syscall

# =============================================================================
# NODE / OS PLANE
# =============================================================================

- rule: CKS Kernel Module Loaded
  desc: init_module/finit_module on a running node — rootkit or driver injection.
  condition: >
    (evt.type in (init_module, finit_module) and evt.dir=<)
  output: >
    Kernel module load attempt
    (evt_time=%evt.time proc=%proc.name cmdline=%proc.cmdline
     user=%user.name loginuid=%user.loginuid container_id=%container.id)
  priority: CRITICAL
  tags: [host, mitre_persistence, T1547.006]
  source: syscall

- rule: CKS Log File Deleted Or Truncated
  desc: Indicator removal — the attacker cleaning up after themselves (T1070.004).
  condition: >
    (evt.type in (unlink, unlinkat, rename, renameat, renameat2) and evt.dir=<
     and (fd.name startswith "/var/log" or evt.arg.path startswith "/var/log"))
    and not proc.name in (logrotate, journald, systemd-journald, rsyslogd)
  output: >
    Log file removed or renamed
    (evt_time=%evt.time target=%evt.arg.path proc=%proc.name
     cmdline=%proc.cmdline user=%user.name loginuid=%user.loginuid
     container_id=%container.id)
  priority: ERROR
  tags: [host, mitre_defense_evasion, T1070.004]
  source: syscall
```

### 5.6 Sobrescribir una regla incluida de fábrica (no hagas un fork de `falco_rules.yaml`)

Falco moderno reemplaza `append: true` con semántica explícita de `override`. Ponelas en `/etc/falco/falco_rules.local.yaml`:

```yaml
# Append an exception to a shipped rule without copying its condition.
- rule: Terminal shell in container
  condition: and not k8smeta.ns.name in (debug-sandbox)
  override:
    condition: append

# Raise the priority of a shipped rule.
- rule: Read sensitive file untrusted
  priority: CRITICAL
  override:
    priority: replace

# Extend a shipped list.
- list: known_binaries
  items: [my-corp-agent, otel-collector]
  override:
    items: append

# Disable a rule that is pure noise in your environment.
- rule: Write below etc
  enabled: false
```

Preferible a ambas opciones: el bloque **`exceptions`**, que se verifica en tiempo de compilación y no puede romper la condición:

```yaml
- rule: CKS Package Management Executed In Container
  exceptions:
    - name: allowed_builder_images
      fields: [container.image.repository, proc.name]
      comps: ["=", in]
      values:
        - [registry.internal.corp/ci/builder, [apt, apt-get, dpkg]]
```

### 5.7 Ejecución y validación

```bash
$ falco --version
Falco version: 0.41.0
Libs version:  0.20.0
Plugin API:    3.10.0
Engine:        modern_ebpf
Driver:
  API version:    8.0.0
  Schema version: 2.0.0
  Default driver: 7.4.0+driver

# --- Syntax-check before you ever restart the daemon -----------------------
$ falco --validate /etc/falco/rules.d/cks-threat-detection.yaml
Fri Aug  5 11:02:14 2026: Validating rules file(s):
Fri Aug  5 11:02:14 2026:    /etc/falco/rules.d/cks-threat-detection.yaml
/etc/falco/rules.d/cks-threat-detection.yaml: Ok
Ok

# A broken rule fails loudly, with a line number:
$ falco --validate /tmp/broken.yaml
/tmp/broken.yaml: Invalid
1 error:
------
Item #0: Compilation error when compiling "proc_started and container.id != host and proc.nmae in (sh)":
  38:52 - filter_check called with nonexistent field proc.nmae

# --- List everything the engine loaded -------------------------------------
$ falco -L | grep -A2 '^CKS Terminal'
CKS Terminal Shell Spawned In Container
  An interactive shell was started inside a container. In an immutable,
  CI-deployed workload this never happens legitimately; it is either an

$ falco --list=syscall | grep -c .
412

# --- Time-boxed capture, JSON to a file (the classic CKS task) -------------
$ falco -r /etc/falco/falco_rules.yaml \
        -r /etc/falco/rules.d/cks-threat-detection.yaml \
        -M 45 \
        -o json_output=true \
        -o priority=warning \
        -o file_output.enabled=true \
        -o file_output.filename=/opt/course/incident.log \
        -o stdout_output.enabled=false
Fri Aug  5 11:07:31 2026: Falco version: 0.41.0 (x86_64)
Fri Aug  5 11:07:31 2026: Falco initialized with configuration files:
Fri Aug  5 11:07:31 2026:    /etc/falco/falco.yaml | schema validation: ok
Fri Aug  5 11:07:31 2026: Loading plugin 'container' from file /usr/share/falco/plugins/libcontainer.so
Fri Aug  5 11:07:31 2026: Loading plugin 'k8smeta' from file /usr/share/falco/plugins/libk8smeta.so
Fri Aug  5 11:07:31 2026: Loading rules from:
Fri Aug  5 11:07:31 2026:    /etc/falco/falco_rules.yaml | schema validation: ok
Fri Aug  5 11:07:31 2026:    /etc/falco/rules.d/cks-threat-detection.yaml | schema validation: ok
Fri Aug  5 11:07:31 2026: Hostname value has been overridden via environment variable to: worker-02
Fri Aug  5 11:07:31 2026: Starting health webserver with threadiness 8, listening on 0.0.0.0:8765
Fri Aug  5 11:07:31 2026: Loaded event sources: syscall
Fri Aug  5 11:07:31 2026: Enabled event sources: syscall
Fri Aug  5 11:07:31 2026: Opening 'syscall' source with modern BPF probe.
Fri Aug  5 11:07:31 2026: One ring buffer every '2' CPUs.
Fri Aug  5 11:08:16 2026: Running for 45 seconds, terminating...
Fri Aug  5 11:08:16 2026: Events detected: 6
Fri Aug  5 11:08:16 2026: Rule counts by severity:
   CRITICAL: 2
   ERROR: 1
   WARNING: 3
Fri Aug  5 11:08:16 2026: Triggered rules by rule name:
   CKS Terminal Shell Spawned In Container: 2
   CKS Package Management Executed In Container: 1
   CKS Service Account Token Read By Non App Process: 1
   CKS Outbound Connection To Non Cluster Destination: 1
   CKS Container Escape Tooling Executed: 1
Fri Aug  5 11:08:16 2026: Syscall event drop monitoring:
   - event drop detected: 0 occurrences
   - num times actions taken: 0
```

Registro JSON de ejemplo:

```json
{
  "hostname": "worker-02",
  "output": "Service account token read by unexpected process (evt_time=11:07:52.331884113 file=/var/run/secrets/kubernetes.io/serviceaccount/token proc=curl cmdline=curl -s -H Authorization: Bearer ... parent=sh user=root container_id=8f3a2b1c9d4e image=registry.internal.corp/payments/api ns=payments pod=api-6d4f8b9c-2xk4z)",
  "output_fields": {
    "container.id": "8f3a2b1c9d4e",
    "container.image.repository": "registry.internal.corp/payments/api",
    "evt.time": 1786014472331884113,
    "fd.name": "/var/run/secrets/kubernetes.io/serviceaccount/token",
    "k8smeta.ns.name": "payments",
    "k8smeta.pod.name": "api-6d4f8b9c-2xk4z",
    "proc.cmdline": "curl -s -H Authorization: Bearer ...",
    "proc.name": "curl",
    "proc.pname": "sh",
    "user.name": "root"
  },
  "priority": "Critical",
  "rule": "CKS Service Account Token Read By Non App Process",
  "source": "syscall",
  "tags": ["T1552.001", "container", "mitre_credential_access", "secrets"],
  "time": "2026-08-05T11:07:52.331884113Z"
}
```

### 5.8 Formato de salida personalizado — la variante favorita del examen

La tarea suele estar formulada así: *"escribí solo `timestamp,container-id,user-name` para la regla X en `/opt/course/detect.log`"*. Se hace en el campo `output:` de la regla, no con `awk`:

```yaml
- rule: CKS Package Management Executed In Container
  output: "%evt.time,%container.id,%user.name"
```

```bash
$ falco -r /etc/falco/rules.d/cks-threat-detection.yaml -M 30 \
        -o json_output=false \
        -o time_format_iso_8601=true \
        -o stdout_output.enabled=false \
        -o file_output.enabled=true \
        -o file_output.filename=/opt/course/detect.log

$ cat /opt/course/detect.log
11:22:04.115332271: Error 2026-08-05T11:22:04+0000,3b9d7f21ea08,root
11:22:31.884190277: Error 2026-08-05T11:22:31+0000,3b9d7f21ea08,root
```

> **Trampa.** Falco siempre antepone a la línea `<time>: <Priority> `. Si la tarea exige *exactamente* tres campos separados por comas, o bien post-procesás, o bien anotás que el prefijo es parte del contrato de Falco y la porción evaluada es el payload. Leé la redacción de la tarea con cuidado; cuando dice "formato del log", se refiere al campo `output:`.

### 5.9 Falco sobre Kubernetes — valores de Helm (completos)

```yaml
# values-falco.yaml
driver:
  enabled: true
  kind: modern_ebpf

collectors:
  enabled: true
  containerd:
    enabled: true
    socket: /run/containerd/containerd.sock
  crio:
    enabled: false
  docker:
    enabled: false
  kubernetes:
    enabled: true          # deploys k8s-metacollector + k8smeta plugin

controller:
  kind: daemonset
  daemonset:
    updateStrategy:
      type: RollingUpdate
      rollingUpdate:
        maxUnavailable: 1

falco:
  rules_files:
    - /etc/falco/falco_rules.yaml
    - /etc/falco/rules.d
  priority: notice
  buffered_outputs: false
  json_output: true
  json_include_output_property: true
  json_include_tags_property: true
  syscall_event_drops:
    threshold: 0.1
    actions: [log, alert]
    rate: 0.03333
    max_burst: 1
  metrics:
    enabled: true
    interval: 1h
    output_rule: true
  http_output:
    enabled: true
    url: "http://falco-falcosidekick:2801/"

customRules:
  cks-threat-detection.yaml: |-
    # (paste the full ruleset from 5.5 here; Helm renders it into
    #  /etc/falco/rules.d/cks-threat-detection.yaml)
    - list: cks_shell_binaries
      items: [ash, bash, csh, ksh, sh, tcsh, zsh, dash, busybox]
    # ... rest of the ruleset ...

resources:
  requests:
    cpu: 100m
    memory: 512Mi
  limits:
    cpu: 1000m
    memory: 1024Mi

tolerations:
  - effect: NoSchedule
    operator: Exists
  - effect: NoExecute
    operator: Exists

priorityClassName: system-node-critical

falcoctl:
  artifact:
    install:
      enabled: true
    follow:
      enabled: true          # auto-update rules from the OCI registry
  config:
    artifact:
      allowedTypes: [rulesfile, plugin]
      install:
        refs: [falco-rules:4]
      follow:
        refs: [falco-rules:4]

falcosidekick:
  enabled: true
  fullfqdn: false
  webui:
    enabled: true
    redis:
      storageEnabled: true
  config:
    debug: false
    customfields: "cluster:prod-eu-1,env:production"
    slack:
      webhookurl: ""                     # set via existingSecret
      minimumpriority: "critical"
      messageformat: "Falco on {{ .Hostname }}"
    loki:
      hostport: "http://loki.monitoring.svc.cluster.local:3100"
      minimumpriority: "notice"
    prometheus:
      extralabels: "cluster,env"
    elasticsearch:
      hostport: ""
      index: "falco"
      minimumpriority: "notice"
```

```bash
$ helm repo add falcosecurity https://falcosecurity.github.io/charts && helm repo update
"falcosecurity" has been added to your repositories
Update Complete. ⎈Happy Helming!⎈

$ helm upgrade --install falco falcosecurity/falco \
    --namespace falco --create-namespace \
    -f values-falco.yaml --wait --timeout 5m
Release "falco" does not exist. Installing it now.
NAME: falco
LAST DEPLOYED: Wed Aug  5 11:35:02 2026
NAMESPACE: falco
STATUS: deployed
REVISION: 1

$ kubectl -n falco get pods -o wide
NAME                                     READY   STATUS    RESTARTS   AGE   NODE
falco-8x2kq                              2/2     Running   0          92s   worker-01
falco-mn4vt                              2/2     Running   0          92s   worker-02
falco-falcosidekick-6d9c74b5f7-jr2wl     1/1     Running   0          92s   worker-01
falco-falcosidekick-ui-7f8b6d94c-x9pl2   1/1     Running   0          92s   worker-02
falco-k8s-metacollector-5c4b7d8f9-tq6mn  1/1     Running   0          92s   worker-01

# Prove the pipeline end to end.
$ kubectl -n payments exec -it deploy/api -- sh -c 'cat /var/run/secrets/kubernetes.io/serviceaccount/token >/dev/null'

$ kubectl -n falco logs ds/falco -c falco --since=60s | jq -r 'select(.priority=="Critical") | .rule'
CKS Service Account Token Read By Non App Process
```

---

## 6. Telemetría de políticas del kernel: detectar antes de aplicar

Tanto seccomp como AppArmor tienen un **modo de solo registro**. Así es como construís un perfil de aplicación (enforcement) sin romper producción — y es una superficie de detección genuina por derecho propio.

| Mecanismo | Modo detección | Modo aplicación | Dónde aterriza la señal |
|---|---|---|---|
| seccomp | `SCMP_ACT_LOG` | `SCMP_ACT_ERRNO` / `SCMP_ACT_KILL_PROCESS` | auditd `type=SECCOMP`, o `dmesg` |
| AppArmor | `complain` (`aa-complain`) | `enforce` (`aa-enforce`) | auditd `apparmor="ALLOWED"` vs `"DENIED"` |
| SELinux | `permissive` | `enforcing` | auditd `type=AVC` |
| Falco | siempre solo detección | vía Talon/motor de respuesta | salidas de Falco |

**`/var/lib/kubelet/seccomp/profiles/audit.json`**

```json
{
  "defaultAction": "SCMP_ACT_LOG"
}
```

**`/var/lib/kubelet/seccomp/profiles/violation.json`** — lista de permitidos con todo lo que la app necesita, registra el resto:

```json
{
  "defaultAction": "SCMP_ACT_LOG",
  "architectures": [
    "SCMP_ARCH_X86_64",
    "SCMP_ARCH_X86",
    "SCMP_ARCH_X32"
  ],
  "syscalls": [
    {
      "names": [
        "accept4", "arch_prctl", "bind", "brk", "clone", "close", "connect",
        "epoll_create1", "epoll_ctl", "epoll_pwait", "execve", "exit_group",
        "fcntl", "fstat", "futex", "getdents64", "getpid", "getrandom",
        "getsockname", "getsockopt", "listen", "mmap", "mprotect", "munmap",
        "nanosleep", "newfstatat", "openat", "prctl", "pread64", "read",
        "readlinkv", "rt_sigaction", "rt_sigprocmask", "sched_getaffinity",
        "sendto", "set_robust_list", "set_tid_address", "setsockopt",
        "sigaltstack", "socket", "write", "writev"
      ],
      "action": "SCMP_ACT_ALLOW"
    },
    {
      "names": ["ptrace", "process_vm_readv", "process_vm_writev",
                "init_module", "finit_module", "delete_module",
                "mount", "umount2", "pivot_root", "setns", "unshare",
                "kexec_load", "bpf", "perf_event_open"],
      "action": "SCMP_ACT_KILL_PROCESS"
    }
  ]
}
```

**Pod que lo usa (sintaxis de campo para AppArmor en Kubernetes ≥ 1.30):**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: payments-api-audited
  namespace: payments
  labels:
    app: payments-api
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: Localhost
      localhostProfile: profiles/violation.json   # relative to /var/lib/kubelet/seccomp
    appArmorProfile:
      type: Localhost
      localhostProfile: k8s-payments-api          # GA field since v1.30
  containers:
    - name: api
      image: registry.internal.corp/payments/api@sha256:9f2c1a...e77b
      imagePullPolicy: IfNotPresent
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        privileged: false
        capabilities:
          drop: ["ALL"]
      ports:
        - name: http
          containerPort: 8080
      volumeMounts:
        - name: tmp
          mountPath: /tmp
      resources:
        requests: {cpu: 100m, memory: 128Mi}
        limits:   {cpu: 500m, memory: 256Mi}
  volumes:
    - name: tmp
      emptyDir:
        medium: Memory
        sizeLimit: 64Mi
```

**Perfil de AppArmor en modo complain** — `/etc/apparmor.d/k8s-payments-api`:

```
#include <tunables/global>

profile k8s-payments-api flags=(attach_disconnected,mediate_deleted,complain) {
  #include <abstractions/base>

  network inet tcp,
  network inet udp,

  file,                                   # observe everything, deny nothing (complain)

  # These would be DENIED in enforce mode; in complain mode they are logged.
  deny /etc/shadow rwklx,
  deny /proc/sys/kernel/** wklx,
  deny /sys/kernel/security/** rwklx,
  deny mount,
  deny ptrace (trace, tracedby, read, readby),

  capability net_bind_service,
}
```

```bash
$ sudo apparmor_parser -r -W /etc/apparmor.d/k8s-payments-api
$ sudo aa-status | grep -A2 'complain mode'
2 profiles are in complain mode.
   k8s-payments-api
   docker-default

# Observe what the workload actually does — this is your detection feed.
$ sudo ausearch -m AVC,SECCOMP -ts recent -i | grep -E 'apparmor=|SECCOMP' | head -6
type=AVC msg=audit(08/05/2026 11:52:03.771:3312) : apparmor="ALLOWED" operation="open"
  profile="k8s-payments-api" name="/etc/shadow" pid=52117 comm="sh"
  requested_mask="r" denied_mask="r" fsuid=10001 ouid=0
type=SECCOMP msg=audit(08/05/2026 11:52:07.114:3319) : auid=unset uid=10001 gid=10001
  ses=unset pid=52140 comm=sh exe=/bin/busybox sig=SIGSYS arch=x86_64 syscall=ptrace
  compat=0 ip=0x7f1a2b3c4d5e code=kill_process

# Aggregate: which syscalls did the workload attempt that the profile does not allow?
$ sudo ausearch -m SECCOMP -ts today --raw | aureport --syscall --summary -i

Syscall Summary Report
=========================
total  syscall
=========================
   47  ptrace
   12  mount
    9  setns
    3  init_module
```

> **El flujo de trabajo.** Ejecutá en `complain`/`SCMP_ACT_LOG` durante un ciclo de negocio completo (incluí los batch jobs y el cierre mensual), recolectá los registros de auditoría, generá la lista de permitidos y recién ahí pasá a `enforce`. El **Security Profiles Operator** automatiza exactamente esto con CRDs `ProfileRecording` (`recorder: bpf` o `recorder: logs`).

---

## 7. Plano: red — detección a nivel de flujos

Los sensores de syscalls ven `connect()`; no ven un paquete que una NetworkPolicy descartó, ni la semántica L7. Para eso necesitás el datapath.

### 7.1 Default-deny es un control de *detección*, no solo de prevención

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: payments
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-allow-explicit
  namespace: payments
spec:
  podSelector:
    matchLabels:
      app: payments-api
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
          podSelector:
            matchLabels:
              app.kubernetes.io/name: ingress-nginx
      ports:
        - protocol: TCP
          port: 8080
  egress:
    # DNS to CoreDNS only.
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    # Postgres inside the namespace.
    - to:
        - podSelector:
            matchLabels:
              app: payments-db
      ports:
        - protocol: TCP
          port: 5432
```

Una vez que esto existe, **cada descarte es una señal**. Sin default-deny no tenés línea base ni eventos de descarte.

### 7.2 Cilium: modo de auditoría a nivel de política y observación con Hubble

`CiliumNetworkPolicy` soporta un modo **audit** vía el estado de aplicación de políticas del endpoint, lo que te permite desplegar una política y observar qué *sería* denegado antes de aplicarla.

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: payments-api-l7-dns
  namespace: payments
spec:
  endpointSelector:
    matchLabels:
      app: payments-api
  egress:
    # L7 DNS visibility: every name the workload resolves is logged.
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: ANY
          rules:
            dns:
              - matchPattern: "*"
    # L7 HTTP visibility on the allowed egress path.
    - toFQDNs:
        - matchName: "api.stripe.com"
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
    - toEndpoints:
        - matchLabels:
            app: payments-db
      toPorts:
        - ports:
            - port: "5432"
              protocol: TCP
```

```bash
$ cilium status --brief
OK

# Put a single endpoint into audit (non-enforcing, log-only) mode:
$ kubectl -n payments get pods -l app=payments-api -o jsonpath='{.items[0].status.podIP}'
10.244.2.87
$ kubectl -n kube-system exec ds/cilium -- cilium endpoint list | grep 10.244.2.87
1842   Disabled  Disabled  24681  k8s:app=payments-api  10.244.2.87  ready
$ kubectl -n kube-system exec ds/cilium -- cilium endpoint config 1842 PolicyAuditMode=Enabled
Endpoint 1842 configuration updated successfully

# Watch what the policy WOULD drop:
$ hubble observe --namespace payments --verdict AUDIT --follow
Aug  5 12:03:11.442: payments/api-6d4f8b9c-2xk4z:41022 (ID:24681) -> 198.51.100.9:443 (world) policy-verdict:none EGRESS AUDITED (TCP Flags: SYN)
Aug  5 12:03:11.610: payments/api-6d4f8b9c-2xk4z:52104 (ID:24681) -> kube-system/coredns-xxx:53 (ID:16) policy-verdict:L3-L4 EGRESS ALLOWED (UDP)

# Real drops, once enforcing:
$ hubble observe --verdict DROPPED --last 20
Aug  5 12:11:04.113: payments/api-6d4f8b9c-2xk4z:44118 (ID:24681) <> 203.0.113.77:9001 (world) Policy denied DROPPED (TCP Flags: SYN)
Aug  5 12:11:05.220: payments/api-6d4f8b9c-2xk4z:44120 (ID:24681) <> 203.0.113.77:9001 (world) Policy denied DROPPED (TCP Flags: SYN)

# DNS exfiltration hunting — long labels, high-entropy subdomains:
$ hubble observe --protocol dns --namespace payments -o json --last 5000 \
  | jq -r 'select(.l7.dns.query != null) | .l7.dns.query' \
  | awk 'length($0) > 60' | sort | uniq -c | sort -rn | head -3
     41 aGVsbG8td29ybGQtZXhmaWx0cmF0aW9uLXBheWxvYWQ.c2.attacker.example.
     37 dGhpcy1pcy1zdGFnZS10d28tb2YtdGhlLWJlYWNvbg.c2.attacker.example.
     33 YmFzZTY0LWVuY29kZWQtc2VjcmV0LW1hdGVyaWFs.c2.attacker.example.

# Anything talking to the API server that should not be:
$ hubble observe --to-identity 1 --last 50 -o compact
Aug  5 12:14:22.001 payments/api-6d4f8b9c-2xk4z:48812 -> kube-apiserver:6443 to-network FORWARDED (TCP Flags: SYN)
```

### 7.3 Tetragon: aplicación y telemetría a nivel de kernel con `TracingPolicy`

Tetragon agrega lo que Falco no puede: **acción síncrona en el kernel** (`Sigkill`, `Override`) en el punto de hook, y hooks a nivel de LSM en vez de en el límite de las syscalls (inmune a TOCTOU sobre argumentos de ruta).

```yaml
apiVersion: cilium.io/v1alpha1
kind: TracingPolicyNamespaced
metadata:
  name: detect-credential-access
  namespace: payments
spec:
  kprobes:
    # ---- Detect reads of credential material via the LSM file hook --------
    - call: "security_file_permission"
      syscall: false
      return: true
      args:
        - index: 0
          type: "file"
        - index: 1
          type: "int"
      returnArg:
        index: 0
        type: "int"
      returnArgAction: "Post"
      selectors:
        - matchArgs:
            - index: 0
              operator: "Prefix"
              values:
                - "/var/run/secrets/kubernetes.io/serviceaccount"
                - "/etc/shadow"
                - "/etc/kubernetes/pki"
                - "/root/.ssh"
            - index: 1
              operator: "Equal"
              values:
                - "4"          # MAY_READ
          matchActions:
            - action: Post

    # ---- Detect AND KILL any attempt to write to /etc/passwd or /etc/shadow
    - call: "security_file_permission"
      syscall: false
      return: true
      args:
        - index: 0
          type: "file"
        - index: 1
          type: "int"
      returnArg:
        index: 0
        type: "int"
      returnArgAction: "Post"
      selectors:
        - matchArgs:
            - index: 0
              operator: "Equal"
              values:
                - "/etc/passwd"
                - "/etc/shadow"
            - index: 1
              operator: "Equal"
              values:
                - "2"          # MAY_WRITE
          matchActions:
            - action: Sigkill

  # ---- Detect every process execution in the namespace -------------------
  tracepoints:
    - subsystem: "raw_syscalls"
      event: "sys_enter"
      args:
        - index: 4
          type: "int64"
      selectors:
        - matchArgs:
            - index: 0
              operator: "InMap"
              values:
                - "101"   # unshare
                - "308"   # setns
                - "165"   # mount
                - "155"   # pivot_root
          matchActions:
            - action: Post
```

```bash
$ kubectl apply -f tracingpolicy-credential-access.yaml
tracingpolicynamespaced.cilium.io/detect-credential-access created

$ kubectl -n kube-system get tracingpolicies,tracingpoliciesnamespaced -A
NAMESPACE   NAME                                                       AGE
payments    tracingpolicynamespaced.cilium.io/detect-credential-access 14s

$ kubectl -n kube-system exec -ti ds/tetragon -c tetragon -- \
    tetra getevents -o compact --namespace payments
🚀 process payments/api-6d4f8b9c-2xk4z /bin/sh
🚀 process payments/api-6d4f8b9c-2xk4z /usr/bin/cat /var/run/secrets/kubernetes.io/serviceaccount/token
📖 read    payments/api-6d4f8b9c-2xk4z /var/run/secrets/kubernetes.io/serviceaccount/token
🚀 process payments/api-6d4f8b9c-2xk4z /usr/bin/vi /etc/shadow
📝 write   payments/api-6d4f8b9c-2xk4z /etc/shadow
💥 exit    payments/api-6d4f8b9c-2xk4z /usr/bin/vi /etc/shadow SIGKILL
```

---

## 8. Análisis comparativo: elegir el sensor

| | **Falco** | **Tetragon** | **Tracee** | **auditd** | **Auditoría de Kubernetes** |
|---|---|---|---|---|---|
| Capa | syscall (tracepoint) | kprobe/LSM/tracepoint | syscall + LSM | syscall (subsistema de audit) | API HTTP |
| Detecta `kubectl create clusterrolebinding` | ❌ (salvo con el plugin `k8saudit`) | ❌ | ❌ | ❌ | ✅ **única fuente** |
| Detecta `cat /etc/shadow` en un pod | ✅ | ✅ | ✅ | ✅ (sin identidad de pod) | ❌ |
| Detecta un paquete descartado | ❌ | ✅ (con Cilium) | parcial | ❌ | ❌ |
| Detecta manipulación de firmware/arranque | ❌ | ❌ | ❌ | parcial | ❌ |
| Enriquecimiento con identidad de Kubernetes | ✅ vía plugin `k8smeta` | ✅ nativo | ✅ | ❌ | ✅ nativo |
| Puede bloquear de forma síncrona | ❌ (asíncrono vía Talon) | ✅ `Sigkill`/`Override` | ✅ (signatures + policies) | ❌ | ✅ (admission es aparte) |
| Coincidencia de rutas segura ante TOCTOU | ⚠️ argumentos de syscall | ✅ hooks LSM | ✅ | ⚠️ | n/a |
| Lenguaje de reglas | DSL de filtros de sysdig | selectores de CRD | signatures Go/Rego | reglas de audit | Policy YAML de audit |
| Madurez del ecosistema de reglas | ★★★★★ | ★★★☆☆ | ★★★☆☆ | ★★★★☆ | ★★☆☆☆ |
| Overhead del nodo (típico) | 2–5 % CPU | 1–3 % CPU | 3–7 % CPU | 1–4 % CPU + disco | 3–8 % CPU del apiserver |
| Estado en CNCF | Graduated | Incubating (Cilium) | Incubating (Aqua) | Upstream de Linux | Upstream de Kubernetes |
| **En el examen CKS** | **primario** | raro | raro | secundario | **primario** |

**Recomendación para una plataforma de producción:** ejecutá **los tres**: auditoría de Kubernetes (plano de usuarios), Falco (plano de workloads) y Hubble o Tetragon (plano de red). Son complementos, no alternativas — las tablas anteriores muestran que cada uno tiene un punto ciego que los otros cubren. Sumá auditd + AIDE + IMA en el nodo para el plano físico/SO. Para el examen, invertí tu tiempo de estudio en Falco y en la política de auditoría.

### 8.1 Solo detección vs. aplicación: el compromiso operativo

| Postura | MTTD | MTTR | Riesgo de disponibilidad | Cuándo elegirla |
|---|---|---|---|---|
| Solo detección (Falco → SIEM → humano) | segundos | minutos–horas | ninguno | Regla nueva, tasa de FP desconocida, workload crítico para el negocio |
| Detección + etiquetado/cuarentena automáticos (Talon: `kubernetes:label`, aislamiento con NetworkPolicy) | segundos | segundos | bajo — el pod sigue corriendo, pierde la red | Por defecto para reglas `Critical` tras 2 semanas de datos limpios en modo solo detección |
| Detección + terminación (Talon: `kubernetes:terminate`) | segundos | segundos | medio — el Deployment reprograma; un `DaemonSet` o un `StatefulSet` singleton puede no hacerlo | Solo reglas de alta confianza; siempre `ignore_daemonsets`/`ignore_statefulsets` |
| Kill dentro del kernel (Tetragon `Sigkill`, seccomp `SCMP_ACT_KILL_PROCESS`) | 0 | 0 | alto — sin apelación, sin contexto | Solo para comportamientos que *nunca* son legítimos (escribir en `/etc/shadow`, `init_module`) |

---

## 9. De la detección a la respuesta

**Falcosidekick** reparte un evento de Falco hacia N destinos. **Falco Talon** es el motor de respuesta que actúa sobre él.

```yaml
# falcosidekick config fragment (chart values .falcosidekick.config)
customfields: "cluster:prod-eu-1,env:production,team:platform-sec"
templatedfields: ""
outputFieldFormat: ""

# Route by priority, not by rule — keeps routing stable as rules evolve.
slack:
  webhookurl: "https://hooks.slack.com/services/XXX"
  minimumpriority: "critical"
  outputformat: "all"
  messageformat: "Falco {{ .Priority }} on {{ .Hostname }}"

loki:
  hostport: "http://loki.monitoring.svc.cluster.local:3100"
  minimumpriority: "debug"      # everything, for retro-hunting
  tenant: "security"
  extralabels: "rule,priority,k8s_ns_name,k8s_pod_name"

prometheus:
  extralabels: "cluster,env,team"

webhook:
  address: "http://falco-talon.falco.svc.cluster.local:2803"
  minimumpriority: "warning"

policyreport:
  enabled: true
  kubeconfig: ""
  minimumpriority: "notice"
  maxevents: 1000
  prunebypriority: true
```

Reglas de respuesta de Talon (el esquema es sensible a la versión — validalo contra el chart que despleguetes):

```yaml
# talon-rules.yaml
- action: Label suspicious pod
  actionner: kubernetes:label
  parameters:
    labels:
      security.corp/quarantine: "true"
      security.corp/incident: "auto"

- action: Isolate pod network
  actionner: kubernetes:networkpolicy
  parameters:
    allow_cidr:
      - "10.0.100.0/24"     # forensic collector only

- action: Terminate pod
  actionner: kubernetes:terminate
  parameters:
    grace_period_seconds: 5
    ignore_daemonsets: true
    ignore_statefulsets: true

---
- rule: Quarantine on credential access
  match:
    rules:
      - "CKS Service Account Token Read By Non App Process"
      - "CKS Sensitive Host File Accessed From Container"
    priority: ">=critical"
    output_fields:
      - "k8smeta.ns.name!=kube-system"
  actions:
    - action: Label suspicious pod
    - action: Isolate pod network

- rule: Terminate on container escape
  match:
    rules:
      - "CKS Container Escape Tooling Executed"
      - "CKS Host Namespace Entered From Container"
    priority: ">=critical"
  actions:
    - action: Label suspicious pod
    - action: Terminate pod
```

> **Regla de diseño.** *Etiquetar + aislar* antes que *terminar*. Terminar destruye la evidencia que necesitás para la revisión post-incidente, y un atacante que nota la muerte instantánea del pod aprende dónde está tu límite de detección. El aislamiento preserva la memoria, `/proc` y el árbol de procesos para forense en vivo, mientras corta la exfiltración.

---

## 10. Verificación y diagnóstico de fallos

### 10.1 Falco no produce ningún evento

```bash
# 1. Is the driver actually attached?
$ kubectl -n falco logs ds/falco -c falco | grep -iE 'Opening|probe|driver|error'
Fri Aug  5 11:07:31 2026: Opening 'syscall' source with modern BPF probe.

# If instead you see:
#   Runtime error: can't open BPF probe. Exiting.
$ ls /sys/kernel/btf/vmlinux || echo "NO BTF → modern_ebpf unavailable"
$ kubectl -n falco set env ds/falco FALCO_BPF_PROBE=""   # fall back to legacy eBPF

# 2. Is the container privileged enough?
$ kubectl -n falco get ds falco -o jsonpath='{.spec.template.spec.containers[0].securityContext}' | jq
{
  "capabilities": {"add": ["SYS_ADMIN","SYS_RESOURCE","SYS_PTRACE","BPF","PERFMON"]},
  "privileged": false
}
# Missing BPF/PERFMON on kernels >=5.8 → probe load fails silently in some builds.

# 3. hostPID / host mounts present?
$ kubectl -n falco get ds falco -o jsonpath='{.spec.template.spec.hostPID}'
true
$ kubectl -n falco get ds falco -o jsonpath='{.spec.template.spec.volumes[*].name}'
etc-falco proc-fs boot-fs lib-modules usr-fs sys-fs containerd-socket

# 4. Health endpoint
$ kubectl -n falco exec ds/falco -c falco -- curl -s localhost:8765/healthz
{"healthy": true}
```

### 10.2 Una regla existe pero nunca dispara

| Síntoma | Causa | Solución |
|---|---|---|
| La regla aparece en `falco -L` pero está muda | `priority:` en `falco.yaml` está por encima de la prioridad de la regla | Bajá `priority:` o subí la de la regla |
| Regla muda, sin error | Un archivo posterior redefine el mismo nombre en `rule:` | `grep -R "rule: <name>" /etc/falco` — gana la última definición |
| Regla muda solo dentro de contenedores | `container.id != host` pero el plugin `container` no llega al socket de CRI | Verificá que `container.id` no sea literalmente `host` en otros eventos; corregí la ruta del socket |
| `k8smeta.ns.name` siempre vacío | `k8s-metacollector` no desplegado / plugin no cargado | `kubectl -n falco get deploy k8s-metacollector`; revisá `load_plugins` |
| Dispara en una ejecución en primer plano con `-M` pero no como servicio | Distinto directorio de reglas, distinto archivo de configuración | `systemctl cat falco-modern-bpf.service` y compará los argumentos `-c`/`-r` |
| Dispara pero los eventos desaparecen aguas abajo | `buffered_outputs: true` y Falco se reinicia | Poné `buffered_outputs: false` |

```bash
# The definitive test: does the engine even see the syscall?
$ falco -r /etc/falco/rules.d/cks-threat-detection.yaml -M 20 \
        -o log_level=debug -o stdout_output.enabled=true 2>&1 | grep -i 'rule.*loaded\|skipp'

# Per-rule hit counters (requires metrics.rules_counters_enabled: true)
$ kubectl -n falco logs ds/falco -c falco | jq -r \
    'select(.rule=="Falco internal: metrics snapshot") | .output_fields
     | to_entries[] | select(.key|startswith("falco.rules_counters"))
     | "\(.key)=\(.value)"' | head
falco.rules_counters.CKS Terminal Shell Spawned In Container=14
falco.rules_counters.CKS Package Management Executed In Container=3
falco.rules_counters.CKS Container Escape Tooling Executed=0
```

### 10.3 Falco está descartando eventos (estás ciego y no lo sabés)

```bash
$ kubectl -n falco logs ds/falco -c falco | grep -i 'drop'
Fri Aug  5 12:31:02 2026: Falco internal: syscall event drop. 41252 system calls dropped in last second.
{"priority":"Critical","rule":"Falco internal: syscall event drop",
 "output":"Falco internal: syscall event drop. 41252 system calls dropped in last second.",
 "output_fields":{"n_drops":41252,"n_drops_buffer_total":41252,"n_evts":1204118}}
```

Remediación, en orden de preferencia:

1. Subir `buf_size_preset` (4 → 6 duplica la memoria del ring por CPU; cuesta RAM).
2. Poner `drop_failed_exit: true` — descarta las syscalls fallidas, típicamente un 20–40 % del volumen.
3. Recortar el conjunto de reglas base: deshabilitá las reglas sobre las que nunca actuás.
4. Reducir `cpus_for_each_buffer` (1 = un buffer por CPU, máxima memoria, mínimos descartes).
5. Mover el workload más ruidoso a un nodo con un límite de recursos dedicado para Falco.

Alertá siempre sobre la regla de descartes en sí. Un Falco silencioso es indistinguible de un clúster limpio.

### 10.4 El API server no arranca después de habilitar la auditoría

```bash
# Static pods don't appear in `kubectl get events` when the apiserver is down.
$ sudo crictl ps -a --name kube-apiserver
CONTAINER      IMAGE          CREATED         STATE    NAME             ATTEMPT
a1b2c3d4e5f6   4b2b0f0a9c1d   9 seconds ago   Exited   kube-apiserver   7

$ sudo crictl logs a1b2c3d4e5f6 2>&1 | tail -5
I0805 12:41:02.118  1 flags.go:64] FLAG: --audit-policy-file="/etc/kubernetes/audit/policy.yaml"
E0805 12:41:02.221  1 run.go:74] "command failed" err="failed to initialize audit backend: \
  error opening audit policy file: open /etc/kubernetes/audit/policy.yaml: no such file or directory"

$ sudo journalctl -u kubelet -n 30 --no-pager | grep -i apiserver
```

Checklist cuando el API server entra en CrashLoop después de un cambio de auditoría:

| Texto del error | Causa raíz |
|---|---|
| `open ...: no such file or directory` | Falta el volumen `hostPath`, o el `mountPath` no coincide con el flag |
| `error opening audit log file: permission denied` | Directorio de logs montado como `readOnly: true`, o propiedad incorrecta |
| `unknown field "omitManagedFields"` | `apiVersion` de la política incorrecto (debe ser `audit.k8s.io/v1`) |
| `invalid policy: level "Meta" is not valid` | Error de tipeo en `level:` — los valores válidos son `None`, `Metadata`, `Request`, `RequestResponse` |
| Arranca, pero el log queda vacío | Todas las peticiones coincidieron con una regla `level: None`; el orden de reglas es "gana la primera coincidencia" |
| Arranca, y después deja al nodo sin memoria (OOM) | `--audit-log-maxsize` sin definir, disco lleno, o un catch-all con `RequestResponse` |

```bash
# Verify the flags actually took effect:
$ kubectl -n kube-system get pod kube-apiserver-cp1 -o yaml \
  | grep -E 'audit-(policy|log|webhook)'
    - --audit-policy-file=/etc/kubernetes/audit/policy.yaml
    - --audit-log-path=/var/log/kubernetes/audit/audit.log
    - --audit-log-maxage=30
    - --audit-log-maxbackup=10
    - --audit-log-maxsize=500

# Verify events are landing and are well-formed JSON:
$ sudo tail -1 /var/log/kubernetes/audit/audit.log | jq -e '.kind == "Event"' && echo VALID
true
VALID

$ sudo ls -lh /var/log/kubernetes/audit/
total 412M
-rw------- 1 root root  87M Aug  5 12:44 audit.log
-rw------- 1 root root  41M Aug  5 09:12 audit-2026-08-05T09-12-04.331.log.gz

# Volume sanity check — events per minute:
$ sudo tail -100000 /var/log/kubernetes/audit/audit.log \
  | jq -r '.requestReceivedTimestamp[0:16]' | uniq -c | tail -5
   1204 2026-08-05T12:40
   1188 2026-08-05T12:41
   1231 2026-08-05T12:42
   1197 2026-08-05T12:43
   1210 2026-08-05T12:44
# ~1200/min = ~1.7M/day. At ~1KB Metadata records that is ~1.7GB/day. Acceptable.
# If you see 20k/min, your noise-suppression rules are not matching. Check rule order.
```

### 10.5 Simulacro de detección de punta a punta (ejecutalo después de cada cambio)

```bash
#!/usr/bin/env bash
# detection-smoke-test.sh — verify each plane produces its expected signal.
set -euo pipefail
NS=detection-drill
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NS" run drill --image=alpine:3.20 --restart=Never \
  --command -- sleep 3600
kubectl -n "$NS" wait --for=condition=Ready pod/drill --timeout=60s

echo "== [workload] interactive shell =="
kubectl -n "$NS" exec drill -- sh -c 'echo shell-spawned'

echo "== [workload] package manager =="
kubectl -n "$NS" exec drill -- sh -c 'apk info >/dev/null 2>&1 || true'

echo "== [data] service account token read =="
kubectl -n "$NS" exec drill -- \
  cat /var/run/secrets/kubernetes.io/serviceaccount/token >/dev/null

echo "== [network] egress to the internet =="
kubectl -n "$NS" exec drill -- \
  sh -c 'wget -q -T 3 -O /dev/null https://example.com || true'

echo "== [users] secret enumeration (should be forbidden + audited) =="
kubectl -n "$NS" get secrets >/dev/null 2>&1 || true

echo "== [users] exec is audited at RequestResponse =="
sleep 5
sudo jq -r 'select(.objectRef.subresource=="exec")
            | select(.objectRef.namespace=="'"$NS"'")
            | .requestReceivedTimestamp + " " + .user.username' \
  /var/log/kubernetes/audit/audit.log | tail -3

echo "== Falco verdict =="
kubectl -n falco logs ds/falco -c falco --since=90s \
  | jq -r 'select(.output_fields["k8smeta.ns.name"]=="'"$NS"'")
           | .priority + "  " + .rule' | sort | uniq -c

kubectl delete namespace "$NS" --wait=false
```

Salida esperada:

```
== Falco verdict ==
      1 Critical  CKS Service Account Token Read By Non App Process
      1 Error     CKS Package Management Executed In Container
      2 Warning   CKS Terminal Shell Spawned In Container
      1 Warning   CKS Outbound Connection To Non Cluster Destination
```

Una línea faltante es un hueco de cobertura, no una prueba aprobada. Conectá este script al CI contra un clúster de staging y hacé fallar el build cuando un plano se quede a oscuras.

---

## 11. Práctica enfocada en el examen

Bajo presión de tiempo, estas son las secuencias que deben ser memoria muscular.

**Patrón de tarea A — "Agregá una regla de Falco que detecte X y escriba en un archivo."**

```bash
# 1. Find the config and the rules directory.
$ ls /etc/falco/
falco.yaml  falco_rules.local.yaml  falco_rules.yaml  rules.d/

# 2. Write the rule into rules.d/ (never into falco_rules.yaml).
$ sudo tee /etc/falco/rules.d/exam.yaml >/dev/null <<'EOF'
- rule: Detect Package Management In Container
  desc: Package manager launched inside a container
  condition: >
    evt.type in (execve, execveat) and evt.dir=< and container.id != host
    and proc.name in (apk, apt, apt-get, dpkg, yum, dnf, rpm, pip, npm)
  output: "%evt.time,%container.id,%user.name"
  priority: ERROR
  source: syscall
EOF

# 3. Validate BEFORE restarting anything.
$ sudo falco --validate /etc/falco/rules.d/exam.yaml
/etc/falco/rules.d/exam.yaml: Ok

# 4. Capture for a bounded time into the requested file.
$ sudo falco -M 45 \
    -o stdout_output.enabled=false \
    -o file_output.enabled=true \
    -o file_output.filename=/opt/course/incidents.log

# 5. Or, if the task wants the daemon running persistently:
$ sudo systemctl restart falco-modern-bpf.service
$ sudo systemctl status falco-modern-bpf.service --no-pager
$ sudo journalctl -u falco-modern-bpf.service -f
```

**Patrón de tarea B — "Habilitá la auditoría con la política P y verificá."**

```bash
$ sudo mkdir -p /etc/kubernetes/audit /var/log/kubernetes/audit
$ sudo vi /etc/kubernetes/audit/policy.yaml            # write the policy
$ sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/apiserver.bak
$ sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml # flags + volume + volumeMount
$ watch -n2 'sudo crictl ps | grep apiserver'          # wait for a fresh container
$ kubectl get --raw /livez?verbose | tail -3
$ sudo tail -f /var/log/kubernetes/audit/audit.log | jq -c '{u:.user.username,v:.verb,r:.objectRef.resource}'
```

**Identificación rápida del pod culpable a partir de un `container.id`:**

```bash
$ CID=8f3a2b1c9d4e
$ sudo crictl ps --id "$CID" -o json | jq -r '.containers[0].labels
    | "\(.["io.kubernetes.pod.namespace"])/\(.["io.kubernetes.pod.name"])"'
payments/api-6d4f8b9c-2xk4z

# Or cluster-wide, without node access:
$ kubectl get pods -A -o json \
  | jq -r --arg cid "$CID" '.items[]
      | select(.status.containerStatuses[]?.containerID | test($cid))
      | "\(.metadata.namespace)/\(.metadata.name) node=\(.spec.nodeName)"'
payments/api-6d4f8b9c-2xk4z node=worker-02
```

---

## 12. Resumen — la tabla de decisión

| Tenés que detectar… | Usá | Por qué nada más funciona |
|---|---|---|
| Un usuario otorgándose `cluster-admin` | audit log de kube-apiserver | Es una petición HTTPS; ningún sensor de nodo la ve |
| Una shell dentro de un contenedor | Falco / Tetragon | El audit log solo ve `pods/exec`, no una `sh` lanzada por la propia app |
| Un token de SA robado y reutilizado desde afuera | Audit log (`sourceIPs` vs. CIDR del clúster) | Solo el API server ve la IP de quien lo presenta |
| Un contenedor escapando al host | Falco (`setns`, `/proc/*/root`) + auditd | Kubernetes no tiene concepto de ruptura de namespace |
| Exfiltración de datos por un puerto permitido | Telemetría L7 / DNS de Hubble | El `connect()` a nivel de syscall no distingue un C2 de una CDN |
| Un binario `kubelet` reemplazado | IMA + AIDE | El kubelet comprometido se reporta a sí mismo como sano |
| Un implante en el firmware | Atestación de PCRs del TPM | Todo lo que está por encima del firmware confía en él |
| Una syscall que tu perfil seccomp bloquearía | seccomp `SCMP_ACT_LOG` + auditd | Aplicar primero rompe producción |

La detección es un sistema, no una herramienta. Instrumentá cada plano, probá que cada uno dispara con el smoke test, alertá sobre el silencio de un sensor tan fuerte como alertás sobre los hallazgos, y transmití todo fuera del nodo antes de que el pod muera.

---

## 13. Referencias

**Currículo y examen**
- CKS Curriculum v1.34 — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Repositorio de currículos de la CNCF — https://github.com/cncf/curriculum

**Kubernetes upstream**
- Auditing — https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Referencia de la API de Audit Policy (`audit.k8s.io/v1`) — https://kubernetes.io/docs/reference/config-api/apiserver-audit.v1/
- Referencia de línea de comandos de kube-apiserver — https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
- Seccomp: restringir las syscalls de un contenedor — https://kubernetes.io/docs/tutorials/security/seccomp/
- AppArmor: restringir el acceso de un contenedor — https://kubernetes.io/docs/tutorials/security/apparmor/
- Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Network Policies — https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Security Checklist — https://kubernetes.io/docs/concepts/security/security-checklist/
- Kubernetes Security Cheat Sheet — https://kubernetes.io/docs/concepts/security/security-checklist/
- Static Pods — https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/

**Falco (CNCF Graduated)**
- Página principal de la documentación — https://falco.org/docs/
- Referencia de reglas — https://falco.org/docs/concepts/rules/
- Campos soportados (referencia de filtros) — https://falco.org/docs/reference/rules/supported-fields/
- Opciones de configuración (`falco.yaml`) — https://falco.org/docs/reference/daemon/config-options/
- Opciones de línea de comandos — https://falco.org/docs/reference/daemon/daemon-cli/
- Drivers (modern eBPF, eBPF, kmod) — https://falco.org/docs/concepts/event-sources/kernel/
- Plugins (`container`, `k8smeta`, `k8saudit`) — https://falco.org/docs/concepts/plugins/
- Descartes de eventos / métricas — https://falco.org/docs/concepts/metrics/
- falcoctl — https://github.com/falcosecurity/falcoctl
- Falcosidekick — https://github.com/falcosecurity/falcosidekick
- Falco Talon (motor de respuesta) — https://github.com/falcosecurity/falco-talon
- Charts de Helm — https://github.com/falcosecurity/charts

**Alternativas basadas en eBPF**
- Documentación de Cilium Tetragon — https://tetragon.io/docs/
- Referencia de TracingPolicy de Tetragon — https://tetragon.io/docs/concepts/tracing-policy/
- Cilium Hubble — https://docs.cilium.io/en/stable/observability/hubble/
- Cilium Network Policy (L7/DNS) — https://docs.cilium.io/en/stable/security/policy/
- Aqua Tracee — https://aquasecurity.github.io/tracee/latest/

**Integridad del nodo y física**
- Framework de auditoría de Linux (`auditd`) — https://github.com/linux-audit/audit-documentation/wiki
- `auditctl(8)` — https://man7.org/linux/man-pages/man8/auditctl.8.html
- `ausearch(8)` — https://man7.org/linux/man-pages/man8/ausearch.8.html
- AIDE — https://aide.github.io/
- IMA/EVM del kernel — https://www.kernel.org/doc/html/latest/security/IMA-templates.html
- Kernel lockdown / Secure Boot — https://man7.org/linux/man-pages/man7/kernel_lockdown.7.html
- `seccomp(2)` y `SECCOMP_RET_LOG` — https://man7.org/linux/man-pages/man2/seccomp.2.html
- Documentación de AppArmor — https://gitlab.com/apparmor/apparmor/-/wikis/Documentation
- Keylime (atestación remota, CNCF sandbox) — https://keylime.dev/

**Modelos de amenazas y benchmarks**
- Matriz MITRE ATT&CK for Containers — https://attack.mitre.org/matrices/enterprise/containers/
- CIS Kubernetes Benchmark — https://www.cisecurity.org/benchmark/kubernetes
- Guía de hardening de Kubernetes de la NSA/CISA — https://media.defense.gov/2022/Aug/29/2003066362/-1/-1/0/CTR_KUBERNETES_HARDENING_GUIDANCE_1.2_20220829.PDF
- Security Profiles Operator — https://github.com/kubernetes-sigs/security-profiles-operator