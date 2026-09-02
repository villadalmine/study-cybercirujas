# 5.4 — Usar apropiadamente herramientas de endurecimiento del kernel como AppArmor, seccomp

> **CKS v1.34 · Dominio 5: Minimización de Vulnerabilidades en Microservicios · Peso 2.5**

---

## 1. El problema arquitectónico: un kernel, N inquilinos

Un nodo worker de Kubernetes que corre 110 pods corre **un** solo kernel Linux. Los namespaces virtualizan la *vista* que un proceso tiene del sistema (PIDs, mounts, red, UTS, IPC, usuarios, cgroups); los cgroups miden *cuánto* consume. Ninguno de los dos angosta la **ABI del kernel** — las ~350 syscalls en `x86_64` más cada `ioctl`, mensaje `netlink`, escritura a `/proc` y atributo de `/sys` alcanzable a través de ellas. Esa ABI es la superficie de ataque compartida y no namespaceada, y es donde aterrizó cada escape de contenedor de la última década:

| CVE | Punto de entrada | Qué hicieron los namespaces al respecto |
|---|---|---|
| CVE-2016-5195 (Dirty COW) | carrera `madvise` + `/proc/self/mem` | Nada — ambos son agnósticos a los namespaces |
| CVE-2019-5736 (runc `/proc/self/exe`) | `open`/`write` sobre el binario del runtime vía `/proc` | Nada |
| CVE-2021-22555 (netfilter heap OOB) | `setsockopt` sobre `IPT_SO_SET_REPLACE` dentro de un user namespace | Nada |
| CVE-2022-0185 (desbordamiento de heap en fs context) | `fsconfig`/`unshare(CLONE_NEWUSER)` | Nada |
| CVE-2022-0847 (Dirty Pipe) | `splice` + flags de pipe | Nada |
| CVE-2024-1086 (nf_tables UAF) | `unshare(CLONE_NEWUSER|CLONE_NEWNET)` + netlink de `nftables` | Nada |

Cada uno de ellos fue mitigado *antes del parche* por (a) un filtro seccomp que devolvía `EPERM` para la syscall, o (b) una política de AppArmor/SELinux que denegaba el acceso al objeto, o (c) ambos. Ese es todo el argumento arquitectónico de este tema: **parchear es reactivo y a nivel de nodo; la política a nivel de syscall y de objeto es proactiva y por workload.** El modelo mental correcto es un trinquete — reducís la superficie de kernel alcanzable una vez, por workload, y queda reducida para cada CVE posterior que resulte vivir detrás de una syscall que ya eliminaste.

### 1.1 Dónde se ubican estas herramientas en la pila de aislamiento

```
┌─────────────────────────────────────────────────────────────────────┐
│ container process                                                   │
├─────────────────────────────────────────────────────────────────────┤
│ glibc / musl                                                        │
├──────────────────────────── syscall boundary ───────────────────────┤
│ ① seccomp-BPF        → runs FIRST, on syscall entry, before the     │
│                        kernel resolves any argument pointer         │
├─────────────────────────────────────────────────────────────────────┤
│ ② capability check   → CAP_SYS_ADMIN, CAP_NET_RAW, …                │
├─────────────────────────────────────────────────────────────────────┤
│ ③ DAC (uid/gid/mode) → classic UNIX permissions                     │
├─────────────────────────────────────────────────────────────────────┤
│ ④ LSM hooks (MAC)    → AppArmor **or** SELinux; ~250 hook points    │
│                        on files, caps, mount, ptrace, signal, net   │
├─────────────────────────────────────────────────────────────────────┤
│ kernel object (inode, socket, task, …)                              │
└─────────────────────────────────────────────────────────────────────┘
```

El orden importa operativamente. seccomp dispara **antes** de los hooks LSM y antes de los chequeos de capabilities, así que una syscall denegada por seccomp nunca llega a AppArmor y nunca produce un registro de auditoría de AppArmor. Cuando estés depurando "falla pero AppArmor no registra nada", ese orden suele ser la respuesta.

### 1.2 Las dos herramientas responden preguntas distintas

| | seccomp | AppArmor |
|---|---|---|
| Pregunta que responde | *¿Qué syscalls puede emitir este proceso?* | *¿Qué objetos puede tocar este proceso, y cómo?* |
| Granularidad | número de syscall + argumentos **escalares** | ruta, capability, mount, ptrace, señal, familia/tipo de socket |
| Punteros de argumentos | **No puede dereferenciarlos** (a prueba de TOCTOU por diseño) | Resuelve rutas completamente a través del hook LSM |
| Punto de aplicación | entrada de la syscall (`seccomp-BPF`, cBPF→eBPF) | hooks LSM en lo profundo de cada subsistema |
| ¿Puede expresar "leer `/etc/passwd` pero no `/etc/shadow`"? | **No** — ambos son `openat`, y la ruta es un puntero | **Sí** |
| ¿Puede expresar "nada de `unshare`, jamás"? | **Sí** | Parcialmente (`deny mount`, `deny pivot_root`, no hay regla directa para `unshare`) |
| Portabilidad | Cualquier Linux ≥ 3.5, cualquier distro | Debian/Ubuntu/SUSE por defecto; ausente en RHEL/Fedora/Rocky (traen SELinux) |

Son complementarias, no alternativas. Una línea base de producción usa **ambas**: seccomp para amputar la superficie de syscalls, AppArmor para restringir qué pueden alcanzar las syscalls sobrevivientes.

---

## 2. seccomp: mecánica que tenés que entender para depurarlo

### 2.1 Modos e instalación

```c
/* Mode 1 — SECCOMP_MODE_STRICT: only read/write/_exit/sigreturn. Useless for containers. */
prctl(PR_SET_SECCOMP, SECCOMP_MODE_STRICT);

/* Mode 2 — SECCOMP_MODE_FILTER: a cBPF program decides per syscall. What Kubernetes uses. */
seccomp(SECCOMP_SET_MODE_FILTER, SECCOMP_FILTER_FLAG_TSYNC, &prog);
```

Un proceso sin privilegios solo puede instalar un filtro si primero establece `PR_SET_NO_NEW_PRIVS`, de lo contrario un binario setuid podría usarse para escapar del filtro. Por eso:

* todo runtime de contenedores establece `no_new_privs` cuando aplica un perfil seccomp;
* `securityContext.allowPrivilegeEscalation: false` también lo establece;
* **los binarios setuid dejan de funcionar** bajo seccomp — el síntoma clásico es `ping` fallando con `socket: Operation not permitted` aunque `/bin/ping` sea `4755`.

### 2.2 Qué puede ver realmente el filtro

```c
struct seccomp_data {
    int   nr;                   /* syscall number                       */
    __u32 arch;                 /* AUDIT_ARCH_X86_64 = 0xc000003e       */
    __u64 instruction_pointer;
    __u64 args[6];              /* raw register values — NOT followed   */
};
```

`args[]` contiene valores de registros. Si un argumento es un puntero (una ruta, un `struct sockaddr`), el filtro ve la dirección, no el contenido. La dereferencia fue excluida deliberadamente: la página de userspace podría reescribirse entre la lectura del filtro y la lectura del kernel (TOCTOU). **Esta es la limitación más importante para internalizar**: seccomp puede expresar "nada de `mount`", no puede expresar "nada de `mount` de `/dev/sda1`".

El chequeo de `arch` es obligatorio en cualquier perfil escrito a mano. En `x86_64` un proceso puede emitir syscalls `x32` (`nr | 0x40000000`), y los *números de syscall difieren* entre ABIs — un filtro que permite `nr == 2` en `x86_64` (`open`) permite algo completamente distinto en `i386`. `libseccomp` y los runtimes OCI manejan esto por vos; el campo `architectures` en un perfil seccomp JSON de Kubernetes es lo que lo controla.

### 2.3 Acciones del filtro y precedencia

| Acción | Valor | Efecto sobre el llamador | Registro de auditoría |
|---|---|---|---|
| `SCMP_ACT_KILL_PROCESS` | `0x80000000` | Muere todo el grupo de hilos, `SIGSYS` | `type=SECCOMP sig=31` |
| `SCMP_ACT_KILL` / `KILL_THREAD` | `0x00000000` | Muere el hilo llamador, `SIGSYS` | `type=SECCOMP sig=31` |
| `SCMP_ACT_TRAP` | `0x00030000` | Se entrega `SIGSYS` — un handler puede capturarlo | sí |
| `SCMP_ACT_ERRNO(n)` | `0x0005xxxx` | La syscall devuelve `-n` (por defecto `EPERM`) | no (salvo `SCMP_ACT_LOG` en otro lado) |
| `SCMP_ACT_NOTIFY` | `0x7fc00000` | Se entrega a un supervisor de userspace vía un notify fd | no |
| `SCMP_ACT_TRACE(n)` | `0x7ff00000` | Decide el supervisor `ptrace` | no |
| `SCMP_ACT_LOG` | `0x7ffc0000` | **Permitida**, pero registrada. La acción de perfilado. | `type=SECCOMP code=0x7ffc0000` |
| `SCMP_ACT_ALLOW` | `0x7fff0000` | Permitida, silenciosa | no |

Los filtros se **apilan**: un proceso puede instalar varios, y todos corren en cada syscall. El kernel devuelve el resultado **más restrictivo** (`KILL_PROCESS` primero, luego valor numérico ascendente). Por lo tanto un filtro nunca puede ampliar lo que un filtro instalado previamente denegó — relevante cuando un inyector de sidecars, un default del runtime y un perfil del workload se aplican todos juntos.

Desde el kernel 5.11 el kernel mantiene un **caché de bitmap** por filtro para syscalls cuya acción es constante sin importar los argumentos, así que el caso común no cuesta ninguna ejecución de BPF. Con `CONFIG_SECCOMP_CACHE_DEBUG` podés inspeccionarlo:

```
$ sudo cat /proc/24518/seccomp_cache | head -5
x86_64 0 ALLOW
x86_64 1 ALLOW
x86_64 2 FILTER
x86_64 3 ALLOW
x86_64 4 ALLOW
```

El overhead práctico en un workload intensivo en syscalls con un kernel moderno es de ~1–3 %; quien rechaza seccomp por motivos de rendimiento suele estar citando números previos a 5.11.

### 2.4 El perfil `RuntimeDefault` — qué bloquea realmente

`RuntimeDefault` no lo define Kubernetes. Es lo que traiga el runtime CRI: containerd lo compila adentro (`contrib/seccomp/seccomp_default.go`, a su vez derivado del `profiles/seccomp/default.json` de Docker), CRI-O tiene un equivalente. Su forma es:

```json
{ "defaultAction": "SCMP_ACT_ERRNO", "defaultErrnoRet": 1, "architectures": [...], "syscalls": [ ...~350 allowed... ] }
```

Aproximadamente 50–60 syscalls quedan denegadas. Las que importan para el examen y para el modelado de amenazas real:

| Syscall(s) denegada(s) | Ataque que elimina |
|---|---|
| `mount`, `umount2`, `pivot_root`, `move_mount`, `fsopen`, `fsconfig` | Escapes basados en mount, CVE-2022-0185 |
| `unshare`, `setns`, `clone` con `CLONE_NEW*` | Pivote de namespaces, CVE-2024-1086, CVE-2021-22555 (todos necesitan un userns nuevo) |
| `bpf` | Cargar eBPF en el kernel del host |
| `init_module`, `finit_module`, `delete_module` | Rootkits de módulos del kernel |
| `kexec_load`, `kexec_file_load`, `reboot` | Toma del host / DoS |
| `add_key`, `keyctl`, `request_key` | Escapes vía el keyring del kernel (CVE-2016-0728) |
| `open_by_handle_at`, `name_to_handle_at` | "Shocker" — acceso a archivos fuera del rootfs |
| `perf_event_open` | Históricamente una enorme superficie de LPE |
| `ptrace` (kernels < 4.8), `process_vm_readv/writev` | Acceso a memoria entre procesos |
| `userfaultfd` | Primitiva de heap-grooming usada en muchas cadenas de LPE |
| `settimeofday`, `clock_settime`, `adjtimex` | Manipulación del reloj del host |
| `swapon`, `swapoff`, `ioperm`, `iopl`, `vm86` | Abuso directo de hardware / memoria |

Varias de ellas se permiten condicionalmente *si el contenedor tiene `CAP_SYS_ADMIN`* (el perfil trae bloques `"includes": {"caps": ["CAP_SYS_ADMIN"]}`). Consecuencia que vale la pena memorizar: **`privileged: true` o `CAP_SYS_ADMIN` reabren `mount`, `unshare` y `setns` incluso con `RuntimeDefault` aplicado.** Endurecer con seccomp sin quitar capabilities es puro teatro.

`RuntimeDefault` *no* es el default. A menos que el kubelet esté configurado de otra manera, un pod sin `seccompProfile` corre **`Unconfined`**.

### 2.5 Convertir `RuntimeDefault` en el default del clúster

```yaml
# /var/lib/kubelet/config.yaml  (KubeletConfiguration, GA since v1.27)
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
seccompDefault: true
```

o `kubelet --seccomp-default=true`.

```
$ sudo systemctl restart kubelet
$ kubectl run probe --image=busybox:1.36 --restart=Never -- sleep 3600
pod/probe created
$ kubectl exec probe -- grep -E '^(NoNewPrivs|Seccomp)' /proc/1/status
NoNewPrivs:	0
Seccomp:	2
Seccomp_filters:	1
```

`Seccomp: 2` significa `SECCOMP_MODE_FILTER`. `0` = deshabilitado, `1` = strict.

**Disciplina de despliegue**: esto pasa cada pod sin perfil explícito de unconfined a filtrado. Hacelo primero en un pool de nodos canario, taintealo, mové workloads representativos ahí, y vigilá `EPERM` en los logs de la aplicación durante al menos un ciclo de negocio completo. El modo de falla no es un crash — es una syscall devolviendo `-EPERM` en silencio dentro de una biblioteca que se traga el error.

### 2.6 Escribir un perfil personalizado

Los perfiles son JSON en formato OCI ubicados bajo la raíz seccomp del kubelet, que es `<kubelet --root-dir>/seccomp` y por defecto es `/var/lib/kubelet/seccomp`. `localhostProfile` es una **ruta relativa a ese directorio**; las rutas absolutas y `..` se rechazan.

**Perfil de auditoría — el que siempre escribís primero.** Permite todo, registra todo, para que puedas cosechar el conjunto real de syscalls de un workload:

```json
{
  "defaultAction": "SCMP_ACT_LOG"
}
```

**Perfil de lista de denegación — quirúrgico, de bajo radio de impacto:**

```json
{
  "defaultAction": "SCMP_ACT_ALLOW",
  "architectures": ["SCMP_ARCH_X86_64", "SCMP_ARCH_X86", "SCMP_ARCH_X32"],
  "syscalls": [
    {
      "names": [
        "mount", "umount2", "pivot_root", "move_mount", "fsopen", "fsconfig",
        "fsmount", "open_tree", "unshare", "setns", "bpf", "perf_event_open",
        "init_module", "finit_module", "delete_module", "kexec_load",
        "kexec_file_load", "open_by_handle_at", "name_to_handle_at",
        "userfaultfd", "process_vm_readv", "process_vm_writev", "ptrace",
        "add_key", "keyctl", "request_key", "reboot", "swapon", "swapoff"
      ],
      "action": "SCMP_ACT_ERRNO",
      "errnoRet": 1,
      "comment": "EPERM. Escape and post-exploitation primitives."
    }
  ]
}
```

**Perfil de lista de permitidos con filtrado de argumentos — la forma de producción.** Este es un perfil completo y funcional para un servicio HTTP en Go enlazado estáticamente; notá el bloque `args` que permite `clone` para hilos mientras rechaza cualquier flag que cree un namespace:

```json
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "defaultErrnoRet": 1,
  "architectures": ["SCMP_ARCH_X86_64"],
  "syscalls": [
    {
      "names": [
        "accept4", "arch_prctl", "bind", "brk", "clock_gettime", "close",
        "connect", "epoll_create1", "epoll_ctl", "epoll_pwait", "eventfd2",
        "execve", "exit", "exit_group", "fcntl", "fstat", "futex",
        "getdents64", "getpid", "getrandom", "getsockname", "getsockopt",
        "gettid", "listen", "madvise", "mmap", "mprotect", "munmap",
        "nanosleep", "newfstatat", "openat", "pread64", "prlimit64",
        "read", "readlinkat", "recvfrom", "rseq", "rt_sigaction",
        "rt_sigprocmask", "rt_sigreturn", "sched_getaffinity", "sched_yield",
        "sendto", "set_robust_list", "set_tid_address", "setsockopt",
        "shutdown", "sigaltstack", "socket", "tgkill", "uname", "write",
        "writev"
      ],
      "action": "SCMP_ACT_ALLOW"
    },
    {
      "names": ["clone"],
      "action": "SCMP_ACT_ALLOW",
      "args": [
        {
          "index": 0,
          "value": 2114060288,
          "valueTwo": 0,
          "op": "SCMP_CMP_MASKED_EQ",
          "comment": "0x7E020000 = CLONE_NEWNS|NEWCGROUP|NEWUTS|NEWIPC|NEWUSER|NEWPID|NEWNET|NEWTIME. Must be zero."
        }
      ]
    },
    {
      "names": ["socket"],
      "action": "SCMP_ACT_ERRNO",
      "errnoRet": 22,
      "args": [
        { "index": 0, "value": 16, "op": "SCMP_CMP_EQ", "comment": "AF_NETLINK → EINVAL" }
      ]
    }
  ]
}
```

Operadores de comparación disponibles en `args`: `SCMP_CMP_NE`, `SCMP_CMP_LT`, `SCMP_CMP_LE`, `SCMP_CMP_EQ`, `SCMP_CMP_GE`, `SCMP_CMP_GT`, `SCMP_CMP_MASKED_EQ` (`(arg & value) == valueTwo`). Múltiples entradas `args` en una misma regla se combinan con **AND**.

### 2.7 Derivar la lista de permitidos de un workload en ejecución

Tres métodos prácticos, en orden creciente de fidelidad:

```
# ① strace on a short-lived run — misses rare paths, but zero infrastructure
$ sudo strace -f -c -U name -p $(pgrep -f checkout-api) -o /tmp/syscalls.txt
$ sort -u /tmp/syscalls.txt | awk '{print $NF}' | paste -sd'","' -
"accept4","arch_prctl","bind","brk",...

# ② SCMP_ACT_LOG profile + auditd — captures everything the kernel sees
$ sudo ausearch -m SECCOMP -ts recent --format raw \
    | grep -oP 'syscall=\K[0-9]+' | sort -un | while read n; do scmp_sys_resolver "$n"; done
openat
read
write
...

# ③ Security Profiles Operator eBPF recorder — the only one safe for long production soaks
```

Siempre unificá las trazas de **al menos** el arranque, el estado estable, una recarga de configuración (`SIGHUP`), un apagado ordenado, y cualquier ruta poco ejercitada (renegociación TLS, core dump, handler de pánico). Los perfiles derivados de una traza de cinco minutos del camino feliz son la causa #1 de incidentes a las 03:00.

---

## 3. AppArmor: mecánica

### 3.1 Modelo

AppArmor es un LSM **basado en rutas**. La política se adjunta a un programa por nombre de perfil; el perfil enumera los accesos permitidos en clases (`file`, `capability`, `network`, `mount`, `ptrace`, `signal`, `unix`, `dbus`). Cualquier clase que menciones pasa a ser deny-por-defecto para todo lo que no hayas permitido; una clase que nunca mencionás queda sin mediar. Las reglas `deny` explícitas tienen precedencia sobre los allow y se restan permanentemente, incluso a través del apilamiento de perfiles.

Contrastá con SELinux, que es **basado en etiquetas**: la política está sobre las etiquetas de inodos (`xattr`) en vez de sobre nombres de ruta. AppArmor es dramáticamente más fácil de escribir y razonar; el precio es que un hard link o un bind mount a una ruta distinta es un sujeto de política distinto.

### 3.2 Modos de perfil

| Modo | Comportamiento | Cómo establecerlo |
|---|---|---|
| `enforce` | Denegar + registrar | `aa-enforce <profile>` o por defecto |
| `complain` | Permitir + registrar (modo de aprendizaje) | `aa-complain`, o `flags=(complain)` |
| `kill` | Denegar + `SIGKILL` al proceso (AppArmor 3.x) | `flags=(kill)` |
| `unconfined` | Sin mediación, perfil cargado pero inerte | `flags=(unconfined)` |

### 3.3 Integración con Kubernetes

El runtime de contenedores aplica el perfil vía el campo OCI `process.apparmorProfile`, ejecutando una transición de perfil al iniciar el contenedor. `RuntimeDefault` bajo containerd es un perfil generado llamado `cri-containerd.apparmor.d`; bajo Docker es `docker-default`.

**El campo de la API (GA desde v1.31; disponible desde v1.30):**

```
$ kubectl explain pod.spec.securityContext.appArmorProfile
GROUP:
KIND:       Pod
VERSION:    v1

FIELD: appArmorProfile <AppArmorProfile>

DESCRIPTION:
    appArmorProfile is the AppArmor options to use by the containers in this pod.
    Note that this field cannot be set when spec.os.name is windows.

FIELDS:
  localhostProfile	<string>
    localhostProfile indicates a profile loaded on the node that should be used.
    The profile must be preconfigured on the node to work. Must match the loaded
    name of the profile. Must be set if and only if type is "Localhost".

  type	<string> -required-
    type indicates which kind of AppArmor profile will be applied. Valid options are:
      Localhost - a profile pre-loaded on the node.
      RuntimeDefault - the container runtime's default profile.
      Unconfined - no AppArmor enforcement.
```

La anotación heredada `container.apparmor.security.beta.kubernetes.io/<container-name>` está **deprecada desde v1.30**. El API server todavía convierte una anotación aislada en el campo por retrocompatibilidad, pero establecer **ambos** con valores en conflicto es un error de validación, y la anotación va a ser eliminada. Escribí el campo; reconocé la anotación cuando heredes un manifiesto viejo.

### 3.4 Una asimetría crítica entre los dos campos `localhostProfile`

| | `seccompProfile.localhostProfile` | `appArmorProfile.localhostProfile` |
|---|---|---|
| Semántica | **Ruta de sistema de archivos**, relativa a `/var/lib/kubelet/seccomp` | **Nombre de perfil** tal como está cargado en el kernel |
| Valor de ejemplo | `operator/prod/checkout-v3.json` | `k8s-checkout-api-v3` |
| Dónde debe existir | como archivo en el nodo | en `/sys/kernel/security/apparmor/profiles` |
| Verificar con | `ls /var/lib/kubelet/seccomp/...` | `sudo aa-status \| grep <name>` |

Confundir esto — poner `/etc/apparmor.d/k8s-deny-write` en el campo de AppArmor — es una trampa estándar de examen y una caída estándar de producción. El valor tiene que coincidir con el `profile <name>` declarado dentro del archivo de perfil, que no necesariamente es igual al nombre del archivo.

### 3.5 Perfiles completos

**Denegar todas las escrituras** — el perfil didáctico canónico, endurecido para contenedores:

```apparmor
# /etc/apparmor.d/k8s-deny-write
abi <abi/3.0>,
include <tunables/global>

profile k8s-deny-write flags=(attach_disconnected,mediate_deleted) {
  include <abstractions/base>

  file,
  network,
  capability,

  deny /** w,
  deny /** l,
  deny /** k,

  audit deny /etc/shadow rwklx,
  audit deny /root/.ssh/** rwklx,
}
```

`flags=(attach_disconnected)` no es opcional en contenedores. Los rootfs de contenedor se construyen con `pivot_root` sobre overlayfs, y el kernel con frecuencia no puede resolver una ruta de vuelta a la raíz del namespace. Sin este flag vas a tener una avalancha de `apparmor="DENIED" ... info="Failed name lookup - disconnected path"` para accesos que tu perfil permite explícitamente. `mediate_deleted` mantiene la mediación sobre archivos deslinkeados pero abiertos.

**Perfil anti-escape** — este es el que vale la pena desplegar sobre workloads reales:

```apparmor
# /etc/apparmor.d/k8s-no-escape
abi <abi/3.0>,
include <tunables/global>

profile k8s-no-escape flags=(attach_disconnected,mediate_deleted) {
  include <abstractions/base>

  # ---- filesystem -----------------------------------------------------
  file,                                   # start permissive, subtract below
  deny /proc/sys/** w,                    # sysctl writes
  deny /proc/sysrq-trigger rwklx,         # host reboot / SysRq
  deny /proc/kcore rklx,                  # host physical memory
  deny /proc/kallsyms rklx,               # KASLR leak for exploit chains
  deny @{PROC}/@{pid}/mem rw,             # Dirty COW style writes
  deny /sys/kernel/security/** rwklx,     # securityfs: unload our own policy
  deny /sys/fs/cgroup/**/release_agent w, # classic cgroup-v1 escape
  deny /sys/firmware/** rwklx,
  deny /dev/kmsg rwklx,
  deny /dev/mem rwklx,
  deny /dev/kmem rwklx,
  deny /**/docker.sock rwklx,             # mounted-socket escape
  deny /**/containerd.sock rwklx,

  # ---- mount namespace ------------------------------------------------
  deny mount,
  deny umount,
  deny pivot_root,

  # ---- process interaction --------------------------------------------
  deny ptrace (trace, read, tracedby, readby) peer=**,
  signal (send, receive) peer=k8s-no-escape,   # only siblings under this profile
  deny signal peer=unconfined,

  # ---- capabilities ----------------------------------------------------
  capability chown,
  capability dac_override,
  capability setuid,
  capability setgid,
  deny capability sys_admin,
  deny capability sys_module,
  deny capability sys_ptrace,
  deny capability sys_rawio,
  deny capability sys_boot,
  deny capability net_raw,
  deny capability mac_admin,
  deny capability mac_override,

  # ---- network ---------------------------------------------------------
  network inet stream,
  network inet dgram,
  network inet6 stream,
  network inet6 dgram,
  network unix stream,
  network unix dgram,
  network netlink raw,          # required by many runtimes/CNI-aware libs
  deny network raw,             # AF_PACKET / raw sockets → no sniffing
  deny network packet,
}
```

**Perfil de mínimo privilegio para un binario específico** — nginx, enumerado exhaustivamente:

```apparmor
# /etc/apparmor.d/k8s-nginx
abi <abi/3.0>,
include <tunables/global>

profile k8s-nginx flags=(attach_disconnected,mediate_deleted) {
  include <abstractions/base>
  include <abstractions/nameservice>
  include <abstractions/openssl>

  # binaries
  /usr/sbin/nginx           mr,
  /docker-entrypoint.sh     rix,
  /bin/dash                 rix,
  /usr/bin/{env,sed,find,touch,mkdir} rix,

  # configuration and content: read-only
  /etc/nginx/**             r,
  /usr/share/nginx/html/**  r,
  /etc/ssl/private/*.key    r,

  # writable state: exactly three paths
  /var/cache/nginx/**       rw,
  /var/run/nginx.pid        rw,
  /var/log/nginx/*.log      w,
  /dev/stdout               w,
  /dev/stderr               w,

  # ports < 1024 need this; drop it if you listen on 8080
  capability net_bind_service,
  capability setuid,
  capability setgid,

  network inet stream,
  network inet6 stream,
  network unix stream,

  deny network raw,
  deny mount,
  deny ptrace (trace, read) peer=**,
  deny /** wl,                    # anything not explicitly writable above
  deny /proc/sys/** w,
}
```

Notá el `rix` sobre el shell y los helpers: `i` = heredar el perfil actual a través del `exec`, de modo que el hijo queda confinado por `k8s-nginx`. Las alternativas son `Px` (transicionar a un perfil con nombre), `Cx` (transicionar a un perfil hijo definido en línea), y `Ux` (**unconfined — una vía de escape, tratá cualquier `Ux` en un perfil revisado como un hallazgo**).

### 3.6 Carga y ciclo de vida

```
$ sudo apparmor_parser -q -r /etc/apparmor.d/k8s-no-escape     # -r = replace (idempotent)
$ sudo aa-status
apparmor module is loaded.
41 profiles are loaded.
39 profiles are in enforce mode.
   /snap/snapd/21759/usr/lib/snapd/snap-confine
   /usr/bin/man
   cri-containerd.apparmor.d
   k8s-deny-write
   k8s-nginx
   k8s-no-escape
   ...
2 profiles are in complain mode.
   k8s-audit-candidate
0 profiles are in kill mode.
0 profiles are in unconfined mode.
23 processes have profiles defined.
23 processes are in enforce mode.
   /usr/sbin/chronyd (912)
   cri-containerd.apparmor.d (24518)
   k8s-nginx (25107)
   ...
0 processes are in complain mode.
0 processes are unconfined but have a profile defined.
```

Sutilezas operativas que muerden:

* `apparmor_parser -r` surte efecto **inmediatamente para los procesos que ya están corriendo**. Eso es un superpoder para hotfixes y una trampa — reemplazar un perfil por uno más estricto puede romper pods en ejecución sin ningún evento a nivel de pod.
* `apparmor_parser -R` (remove) deja los contenedores en ejecución **unconfined**, en silencio. Nunca remuevas un perfil que los pods todavía referencian.
* No podés adjuntar un perfil a un contenedor en ejecución. La transición ocurre en el momento del `exec`; cambiar el campo requiere recrear el pod.
* Los perfiles son estado del kernel, no archivos. Un reinicio del nodo recarga lo que esté en `/etc/apparmor.d` vía el `apparmor.service`; un perfil que cargaste desde `/tmp` desaparece.

---

## 4. Análisis de compromisos

### 4.1 Elegir un mecanismo

| Mecanismo | Frena syscalls | Frena acceso a objetos | Prerrequisito del nodo | Costo de rendimiento | Esfuerzo de autoría | Radio de impacto si está mal |
|---|---|---|---|---|---|---|
| Quitar capabilities | indirectamente | indirectamente | ninguno | ~0 | trivial | bajo, falla ruidosamente (`EPERM`) |
| seccomp `RuntimeDefault` | sí (~55) | no | ninguno | ~1 % | nulo | bajo |
| seccomp `Localhost` lista de permitidos | sí (~300) | no | archivo en cada nodo | 1–3 % | **alto** | **alto** — una syscall omitida = crash loop |
| AppArmor `RuntimeDefault` | no | mínimo | nodo con AppArmor habilitado | ~1 % | nulo | bajo |
| AppArmor `Localhost` | no | sí | perfil cargado en cada nodo | 1–4 % | medio | medio, `EACCES` |
| SELinux (`seLinuxOptions`) | no | sí | distro con SELinux + política | 2–5 % | alto | alto |
| User namespaces (`hostUsers: false`) | no | remapea uid 0 | kernel ≥ 6.3 + idmapped mounts | bajo | trivial | medio (propiedad de archivos) |
| gVisor (`runsc`) | las reimplementa | sí | RuntimeClass | 10–50 % con muchas syscalls | nulo | medio (huecos de compatibilidad) |
| Kata Containers | kernel separado | sí | virt anidada / bare metal | 5–15 %, +150 MB/pod | nulo | bajo |

Guía arquitectónica: **`RuntimeDefault` para ambos, en todos lados, como piso, impuesto por control de admisión.** Escalá a listas de permitidos `Localhost` solo para workloads expuestos a internet, que procesen entrada no confiable, o que manejen datos regulados — el costo operativo de un perfil a medida es recurrente (cada actualización de imagen puede cambiar el conjunto de syscalls), así que gastalo donde el riesgo lo justifique.

### 4.2 Interacción con los Pod Security Standards

| Control | `privileged` | `baseline` | `restricted` |
|---|---|---|---|
| `seccompProfile.type` | cualquiera | cualquiera (incl. `Unconfined`) | debe ser `RuntimeDefault` o `Localhost`; `Unconfined` **prohibido**; debe estar en el pod o en cada contenedor + contenedores efímeros/init |
| `appArmorProfile.type` | cualquiera | solo `RuntimeDefault` o `Localhost` | igual que baseline |

Así que `restricted` te da seccomp, y *ninguno* de los niveles fuerza un perfil de AppArmor distinto del default. Si tu narrativa de cumplimiento dice "MAC impuesto por workload", PSS por sí solo no lo entrega — necesitás política de admisión.

---

## 5. Manifiestos de producción

### 5.1 Namespace con línea base impuesta

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: prod
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.34
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

### 5.2 Distribución de perfiles del lado del nodo (AppArmor)

Los perfiles son estado local del nodo. Kubernetes no los va a distribuir por vos. Este DaemonSet los carga y luego etiqueta el nodo para que los pods puedan exigir un nodo que los tenga.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: apparmor-profiles
  namespace: kube-system
  labels:
    app.kubernetes.io/name: apparmor-loader
data:
  k8s-no-escape: |
    abi <abi/3.0>,
    include <tunables/global>

    profile k8s-no-escape flags=(attach_disconnected,mediate_deleted) {
      include <abstractions/base>
      file,
      network inet stream,
      network inet6 stream,
      network unix stream,
      deny network raw,
      deny mount,
      deny umount,
      deny pivot_root,
      deny ptrace (trace, read) peer=**,
      deny /proc/sys/** w,
      deny /proc/sysrq-trigger rwklx,
      deny /sys/kernel/security/** rwklx,
      deny /sys/fs/cgroup/**/release_agent w,
      deny /dev/kmsg rwklx,
      deny capability sys_admin,
      deny capability sys_module,
      deny capability sys_ptrace,
      deny capability net_raw,
    }
  k8s-nginx: |
    abi <abi/3.0>,
    include <tunables/global>

    profile k8s-nginx flags=(attach_disconnected,mediate_deleted) {
      include <abstractions/base>
      include <abstractions/nameservice>
      /usr/sbin/nginx           mr,
      /docker-entrypoint.sh     rix,
      /bin/dash                 rix,
      /etc/nginx/**             r,
      /usr/share/nginx/html/**  r,
      /var/cache/nginx/**       rw,
      /var/run/nginx.pid        rw,
      /dev/std{out,err}         w,
      capability net_bind_service,
      capability setuid,
      capability setgid,
      network inet stream,
      network inet6 stream,
      deny network raw,
      deny mount,
      deny /** wl,
    }
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: apparmor-loader
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: apparmor-loader
rules:
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["get", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: apparmor-loader
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: apparmor-loader
subjects:
  - kind: ServiceAccount
    name: apparmor-loader
    namespace: kube-system
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: apparmor-loader
  namespace: kube-system
  labels:
    app.kubernetes.io/name: apparmor-loader
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: apparmor-loader
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
  template:
    metadata:
      labels:
        app.kubernetes.io/name: apparmor-loader
      annotations:
        checksum/profiles: "sha256-REPLACED-BY-CI"   # forces a roll when profiles change
    spec:
      serviceAccountName: apparmor-loader
      nodeSelector:
        kubernetes.io/os: linux
      tolerations:
        - operator: Exists
      hostPID: true
      priorityClassName: system-node-critical
      terminationGracePeriodSeconds: 5
      containers:
        - name: loader
          image: ubuntu:24.04
          securityContext:
            privileged: true          # required: writes kernel policy via securityfs
            appArmorProfile:
              type: Unconfined        # a confined loader cannot load policy
          command: ["/bin/bash", "-c"]
          args:
            - |
              set -euo pipefail
              apt-get update -qq && apt-get install -y -qq apparmor-utils curl >/dev/null

              install -d /host/etc/apparmor.d
              cp /profiles/* /host/etc/apparmor.d/

              for p in /profiles/*; do
                name="$(basename "$p")"
                nsenter --mount=/proc/1/ns/mnt -- \
                  apparmor_parser -q -r "/etc/apparmor.d/${name}"
                echo "loaded ${name}"
              done

              # label the node so workloads can require the profile set
              TOKEN="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
              CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
              curl -sS --cacert "$CA" \
                -H "Authorization: Bearer ${TOKEN}" \
                -H "Content-Type: application/strategic-merge-patch+json" \
                -X PATCH \
                --data '{"metadata":{"labels":{"security.example.com/apparmor-profiles":"v3"}}}' \
                "https://kubernetes.default.svc/api/v1/nodes/${NODE_NAME}" >/dev/null
              echo "node ${NODE_NAME} labelled"

              sleep infinity
          env:
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          resources:
            requests: { cpu: 10m, memory: 64Mi }
            limits:   { memory: 192Mi }
          volumeMounts:
            - name: profiles
              mountPath: /profiles
              readOnly: true
            - name: host-apparmor-d
              mountPath: /host/etc/apparmor.d
            - name: host-proc
              mountPath: /proc
      volumes:
        - name: profiles
          configMap:
            name: apparmor-profiles
        - name: host-apparmor-d
          hostPath:
            path: /etc/apparmor.d
            type: Directory
        - name: host-proc
          hostPath:
            path: /proc
            type: Directory
```

El mismo patrón, sin el `nsenter`, distribuye el JSON de seccomp a `/var/lib/kubelet/seccomp/`. La etiqueta del nodo es la parte importante: cierra la carrera donde un pod se agenda en un nodo cuyo loader no terminó, lo que de otro modo se manifiesta como un `CreateContainerError` intermitente durante el escalado del clúster.

### 5.3 Workload que consume ambos

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout-api
  namespace: prod
  labels:
    app.kubernetes.io/name: checkout-api
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: checkout-api
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: security.example.com/apparmor-profiles
                    operator: In
                    values: ["v3"]
      automountServiceAccountToken: false
      # ---- pod-level defaults, inherited by every container ----
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: Localhost
          localhostProfile: operator/prod/checkout-api-v3.json
        appArmorProfile:
          type: Localhost
          localhostProfile: k8s-no-escape
      initContainers:
        - name: migrate
          image: registry.example.com/checkout-migrate:1.9.3
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
            # init containers inherit the pod profiles; override only if the
            # migration tool needs a syscall the API profile omits
            seccompProfile:
              type: RuntimeDefault
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { memory: 256Mi }
      containers:
        - name: api
          image: registry.example.com/checkout-api:1.9.3
          ports:
            - name: http
              containerPort: 8080
          securityContext:
            allowPrivilegeEscalation: false
            privileged: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
          livenessProbe:
            httpGet: { path: /healthz, port: http }
            initialDelaySeconds: 10
          readinessProbe:
            httpGet: { path: /readyz, port: http }
          resources:
            requests: { cpu: 250m, memory: 256Mi }
            limits:   { memory: 512Mi }
          volumeMounts:
            - name: tmp
              mountPath: /tmp
        - name: metrics-sidecar
          image: registry.example.com/otel-collector:0.108.0
          # ---- container-level override: sidecar keeps the loose defaults ----
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
            seccompProfile:
              type: RuntimeDefault
            appArmorProfile:
              type: RuntimeDefault
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits:   { memory: 128Mi }
      volumes:
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 32Mi
```

### 5.4 Imposición en admisión con `ValidatingAdmissionPolicy`

PSS `restricted` no prohíbe `appArmorProfile: Unconfined` por su propia vía, y muchos clústeres todavía no pueden correr `restricted` en todos lados. La política CEL nativa cierra el hueco sin depender de un webhook:

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: require-kernel-hardening
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["pods"]
  variables:
    - name: allContainers
      expression: >-
        object.spec.containers +
        (has(object.spec.initContainers) ? object.spec.initContainers : []) +
        (has(object.spec.ephemeralContainers) ? object.spec.ephemeralContainers : [])
    - name: podSeccomp
      expression: >-
        has(object.spec.securityContext) && has(object.spec.securityContext.seccompProfile)
          ? object.spec.securityContext.seccompProfile.type : ""
    - name: podAppArmor
      expression: >-
        has(object.spec.securityContext) && has(object.spec.securityContext.appArmorProfile)
          ? object.spec.securityContext.appArmorProfile.type : ""
  validations:
    - expression: >-
        variables.allContainers.all(c,
          (has(c.securityContext) && has(c.securityContext.seccompProfile)
            ? c.securityContext.seccompProfile.type
            : variables.podSeccomp) in ['RuntimeDefault', 'Localhost'])
      message: "every container must resolve to seccompProfile RuntimeDefault or Localhost"
      reason: Forbidden
    - expression: >-
        variables.allContainers.all(c,
          (has(c.securityContext) && has(c.securityContext.appArmorProfile)
            ? c.securityContext.appArmorProfile.type
            : variables.podAppArmor) in ['RuntimeDefault', 'Localhost'])
      message: "every container must resolve to appArmorProfile RuntimeDefault or Localhost"
      reason: Forbidden
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: require-kernel-hardening
spec:
  policyName: require-kernel-hardening
  validationActions: ["Deny", "Audit"]
  matchResources:
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system", "kube-node-lease"]
```

```
$ kubectl apply -f unconfined-pod.yaml
Error from server (Forbidden): error when creating "unconfined-pod.yaml": pods "debug" is
forbidden: ValidatingAdmissionPolicy 'require-kernel-hardening' with binding
'require-kernel-hardening' denied request: every container must resolve to seccompProfile
RuntimeDefault or Localhost
```

### 5.5 Security Profiles Operator (grabación y distribución a escala)

```
$ kubectl apply -f https://github.com/kubernetes-sigs/security-profiles-operator/releases/download/v0.8.6/operator.yaml
$ kubectl -n security-profiles-operator get pods
NAME                                         READY   STATUS    RESTARTS   AGE
security-profiles-operator-7f9c8d5b6-2xk4l   1/1     Running   0          51s
spod-4nq9x                                   3/3     Running   0          38s
spod-hb7zz                                   3/3     Running   0          38s
```

Habilitá el grabador eBPF, y después grabá un workload en vivo:

```yaml
apiVersion: security-profiles-operator.x-k8s.io/v1alpha1
kind: SecurityProfilesOperatorDaemon
metadata:
  name: spod
  namespace: security-profiles-operator
spec:
  enableBpfRecorder: true
  enableAppArmor: true
---
apiVersion: security-profiles-operator.x-k8s.io/v1alpha1
kind: ProfileRecording
metadata:
  name: checkout-api-recording
  namespace: prod
spec:
  kind: SeccompProfile
  recorder: bpf
  mergeStrategy: containers      # union across all replicas
  podSelector:
    matchLabels:
      app.kubernetes.io/name: checkout-api
```

```
$ kubectl -n prod delete deploy checkout-api        # recording is finalised on pod exit
$ kubectl -n prod get seccompprofiles
NAME                              STATUS      AGE
checkout-api-recording-api        Installed   12s
checkout-api-recording-metrics    Installed   12s

$ kubectl -n prod get seccompprofile checkout-api-recording-api -o jsonpath='{.status.localhostProfile}'
operator/prod/checkout-api-recording-api.json
```

Ese valor de `status.localhostProfile` es exactamente lo que va en `seccompProfile.localhostProfile`; SPO se encarga de escribir el archivo en cada nodo y reconciliarlo. El CRD equivalente de AppArmor (`AppArmorProfile`, alpha — verificá el esquema contra la versión que instales) cubre la distribución de perfiles sin el DaemonSet de arriba.

---

## 6. Verificación y diagnóstico de fallas

### 6.1 Verificación positiva, de adentro hacia afuera

```
# ---- 1. Is the policy visible to the process? ----
$ kubectl -n prod exec deploy/checkout-api -c api -- cat /proc/1/attr/current
k8s-no-escape (enforce)

$ kubectl -n prod exec deploy/checkout-api -c api -- grep -E '^(NoNewPrivs|Seccomp)' /proc/1/status
NoNewPrivs:	1
Seccomp:	2
Seccomp_filters:	1

$ kubectl -n prod exec deploy/checkout-api -c api -- grep -E '^Cap(Prm|Eff|Bnd)' /proc/1/status
CapPrm:	0000000000000000
CapEff:	0000000000000000
CapBnd:	0000000000000000

# ---- 2. Does the policy actually deny? Test, do not assume. ----
$ kubectl -n prod exec deploy/checkout-api -c api -- touch /etc/probe
touch: cannot touch '/etc/probe': Permission denied
command terminated with exit code 1

$ kubectl -n prod exec deploy/checkout-api -c api -- unshare -Urn /bin/true
unshare: unshare failed: Operation not permitted
command terminated with exit code 1

$ kubectl -n prod exec deploy/checkout-api -c api -- mount -t proc proc /mnt
mount: /mnt: permission denied.
command terminated with exit code 32

# ---- 3. What did the runtime actually receive? Ground truth on the node. ----
$ CID=$(sudo crictl ps --name '^api$' -q | head -1)
$ sudo crictl inspect "$CID" | jq -r '.info.runtimeSpec.process.apparmorProfile'
k8s-no-escape
$ sudo crictl inspect "$CID" | jq -r '.info.runtimeSpec.linux.seccomp.defaultAction'
SCMP_ACT_ERRNO
$ sudo crictl inspect "$CID" | jq '[.info.runtimeSpec.linux.seccomp.syscalls[].names[]] | length'
54
$ sudo crictl inspect "$CID" | jq -r '.info.runtimeSpec.process.noNewPrivileges'
true
```

`crictl inspect` es el chequeo autoritativo. `kubectl get pod -o yaml` muestra la *intención*; solo el runtime spec muestra lo que se aplicó. Si los dos difieren, sospechá de un webhook mutante o de un kubelet desactualizado.

### 6.2 Prerrequisitos del nodo

```
$ cat /sys/module/apparmor/parameters/enabled
Y
$ cat /sys/kernel/security/lsm
lockdown,capability,landlock,yama,apparmor,bpf
$ grep -c . /sys/kernel/security/apparmor/profiles
41
$ grep -E 'CONFIG_SECCOMP=|CONFIG_SECCOMP_FILTER=' /boot/config-$(uname -r)
CONFIG_SECCOMP=y
CONFIG_SECCOMP_FILTER=y
$ kubectl get nodes -o custom-columns=NAME:.metadata.name,OS:.status.nodeInfo.osImage,KERNEL:.status.nodeInfo.kernelVersion
NAME       OS                   KERNEL
node-01    Ubuntu 24.04.1 LTS   6.8.0-45-generic
node-02    Ubuntu 24.04.1 LTS   6.8.0-45-generic
```

Si `/sys/module/apparmor/parameters/enabled` falta o es `N`, AppArmor no se puede usar en ese nodo — un pod con AppArmor `Localhost` o incluso `RuntimeDefault` va a fallar ahí. En nodos de la familia RHEL esto es lo esperado: usá SELinux (`seLinuxOptions`) en su lugar, y mantené seccomp como la mitad portable de la estrategia.

### 6.3 Catálogo de fallas

| Síntoma | Causa raíz | Confirmar con | Solución |
|---|---|---|---|
| `CreateContainerError`, evento: `apparmor profile not loaded` / `apparmor failed to apply profile` | Perfil ausente en el nodo agendado | `sudo aa-status \| grep <name>` en ese nodo | Correr el DaemonSet loader; agregar node affinity sobre la etiqueta del loader |
| Pod `Blocked`, `Reason: AppArmor`, `Cannot enforce AppArmor: ...` | Handler de admisión de un kubelet viejo (comportamiento pre-GA) | `kubectl describe pod` | La misma solución; notá que los kubelets modernos delegan esto al runtime, así que el mensaje difiere según la versión |
| `Error: failed to generate spec: cannot load seccomp profile ".../x.json": no such file` | Archivo seccomp faltante bajo `/var/lib/kubelet/seccomp` | `ls -l /var/lib/kubelet/seccomp/<path>` | Distribuir el archivo; verificar que `localhostProfile` sea **relativo** |
| `field is immutable` al actualizar el pod | `securityContext` no se puede parchear en el lugar | — | Recrear el pod / rotar el Deployment |
| El contenedor sale con **159** repetidamente | `SIGSYS` (128+31) por `SCMP_ACT_KILL` | `dmesg \| grep -i seccomp`; `kubectl get pod -o jsonpath='{..exitCode}'` | Identificar la syscall en el registro de auditoría, agregarla, o pasar el perfil a `SCMP_ACT_ERRNO` mientras depurás |
| La app registra `Operation not permitted` (`EPERM`), nada en `dmesg` | seccomp `SCMP_ACT_ERRNO` — silencioso por diseño | Cambiar temporalmente a un perfil `SCMP_ACT_LOG` | Agregar la syscall a la lista de permitidos |
| La app registra `Permission denied` (`EACCES`) **y** `dmesg` muestra `apparmor="DENIED"` | Denegación de objeto por AppArmor | `dmesg \| grep DENIED` | Agregar la regla; revisar `requested_mask` |
| Avalancha de `info="Failed name lookup - disconnected path"` | Falta `flags=(attach_disconnected)` | inspeccionar el encabezado del perfil | Agregar el flag, `apparmor_parser -r` |
| `ping` falla con `Operation not permitted` como root | `no_new_privs` puesto por seccomp/`allowPrivilegeEscalation:false` rompió el binario setuid | `grep NoNewPrivs /proc/1/status` → `1` | Usar una imagen con capability de archivo `cap_net_raw`, o aceptar la pérdida |
| DNS se rompe tras aplicar un perfil personalizado | Falta `network netlink raw` o `abstractions/nameservice` | `dmesg \| grep DENIED \| grep netlink` | Agregar la regla |
| La política funciona en node-01, falla en node-03 | El conjunto de perfiles derivó entre nodos | `for n in $(...); do ssh $n aa-status; done` | Etiqueta de nodo + affinity; migrar a SPO |
| seccomp `RuntimeDefault` aplicado pero el contenedor igual monta sistemas de archivos | El contenedor tiene `CAP_SYS_ADMIN` / es privilegiado; el perfil por defecto permite esas syscalls cuando se posee la capability | `grep CapEff /proc/1/status` | Quitar `ALL` las capabilities — seccomp no es un sustituto |

### 6.4 Leer la salida de auditoría del kernel

**Denegación de AppArmor:**

```
$ sudo dmesg -T | grep -i apparmor | tail -3
[Mon Aug  4 14:26:52 2026] audit: type=1400 audit(1754317612.884:212): apparmor="DENIED" \
  operation="mknod" class="file" profile="k8s-no-escape" name="/etc/probe" pid=25811 \
  comm="touch" requested_mask="c" denied_mask="c" fsuid=0 ouid=0
[Mon Aug  4 14:27:03 2026] audit: type=1400 audit(1754317623.117:213): apparmor="DENIED" \
  operation="mount" class="mount" profile="k8s-no-escape" name="/mnt/" pid=25840 \
  comm="mount" fstype="proc" srcname="proc"
[Mon Aug  4 14:27:19 2026] audit: type=1400 audit(1754317639.552:214): apparmor="DENIED" \
  operation="capable" class="cap" profile="k8s-no-escape" pid=25871 comm="ip" \
  capability=12  capname="net_admin"
```

Decodificación de campos:

| Campo | Significado |
|---|---|
| `operation` | El hook LSM (`open`, `mknod`, `mount`, `capable`, `ptrace`, `signal`, `exec`) |
| `profile` | Cuál perfil lo denegó — confirma que está adjunto el correcto |
| `requested_mask` / `denied_mask` | `r` lectura, `w` escritura, `a` append, `x` ejecución, `m` mmap-exec, `k` lock, `l` link, `c` creación, `d` borrado |
| `comm` | El binario — te dice *qué* proceso dentro del contenedor |
| `capname` | Para `operation="capable"`, la capability faltante |

Convertí denegaciones en reglas mecánicamente:

```
$ sudo aa-logprof -f /var/log/audit/audit.log
Reading log entries from /var/log/audit/audit.log.
Updating AppArmor profiles in /etc/apparmor.d.

Profile:  k8s-nginx
Path:     /var/lib/nginx/tmp/client_body
New Mode: owner rw
Severity: 4

 [1 - owner /var/lib/nginx/tmp/client_body rw,]
  2 - owner /var/lib/nginx/tmp/* rw,
  3 - owner /var/lib/nginx/tmp/** rw,
(A)llow / [(D)eny] / (I)gnore / (G)lob / Glob with (E)xtension / (N)ew / ...
```

**Registro de auditoría de seccomp:**

```
$ sudo ausearch -m SECCOMP -ts recent -i | tail -6
type=SECCOMP msg=audit(08/04/2026 14:31:02.221:318) : auid=unset uid=root gid=root ses=unset \
  pid=26011 comm=chmod exe=/usr/bin/chmod sig=SIGSYS arch=x86_64 syscall=fchmodat compat=0 \
  ip=0x7f2c1d0a4b47 code=kill_thread
```

Forma cruda cuando la interpretación con `-i` no está disponible:

```
type=SECCOMP msg=audit(1754317862.221:318): auid=4294967295 uid=0 gid=0 ses=4294967295 \
  pid=26011 comm="chmod" exe="/usr/bin/chmod" sig=31 arch=c000003e syscall=268 compat=0 \
  ip=0x7f2c1d0a4b47 code=0x0
```

Decodificalo:

```
$ scmp_sys_resolver 268
fchmodat
$ ausyscall x86_64 268
fchmodat
$ printf 'arch=c000003e is AUDIT_ARCH_X86_64\n'
arch=c000003e is AUDIT_ARCH_X86_64
```

`code=0x0` → `SECCOMP_RET_KILL_THREAD`. `code=0x7ffc0000` → `SECCOMP_RET_LOG` (permitida, solo auditoría). `code=0x00050001` → `SECCOMP_RET_ERRNO(EPERM)`.

### 6.5 El árbol de decisión de diagnóstico

```
Container fails to START (CreateContainerError / Blocked)
├─ event mentions "apparmor" → profile not loaded on the node
│    → aa-status on THAT node; check the loader DaemonSet; check node affinity
├─ event mentions "seccomp profile" → file missing under /var/lib/kubelet/seccomp
│    → ls the path; check localhostProfile is relative, no leading "/", no ".."
└─ event mentions "no such file or directory: unknown" on /proc/self/attr
     → AppArmor not enabled on the node kernel

Container STARTS then dies
├─ exitCode 159 → SIGSYS → seccomp KILL. ausearch -m SECCOMP → scmp_sys_resolver
└─ exitCode 1/2 with app error → read the errno:
     ├─ EPERM  and dmesg silent            → seccomp SCMP_ACT_ERRNO
     ├─ EACCES and dmesg apparmor="DENIED" → AppArmor
     ├─ EPERM  and CapEff missing the bit  → capability drop, not MAC
     └─ EACCES and dmesg silent            → plain DAC (uid/gid/mode) or readOnlyRootFilesystem

Container RUNS but a feature silently misbehaves
└─ swap to SCMP_ACT_LOG + apparmor complain mode, exercise the feature,
   diff the audit log against the profile, then re-enforce
```

### 6.6 El ciclo seguro de iteración para un perfil nuevo

```
1. Deploy with defaultAction: SCMP_ACT_LOG and AppArmor flags=(complain)
2. Run the workload through: startup, steady state, SIGHUP reload,
   TLS handshake, backup path, graceful shutdown, OOM/panic path
3. Harvest:
     ausearch -m SECCOMP -ts today --format raw | grep -oP 'syscall=\K[0-9]+' | sort -un
     aa-logprof -f /var/log/audit/audit.log
4. Generate the allow-list; keep a diff against the previous version in git
5. Re-deploy to ONE canary replica in enforce mode; soak ≥ 24 h
6. Promote. Version the profile name (…-v3), never mutate in place —
   `apparmor_parser -r` changes behaviour of running pods with no rollout event
```

Regla práctica: nunca regeneres un perfil a partir de una traza más corta que el job periódico más lento del workload.

---

## 7. Checklist enfocado en el examen

* `securityContext.seccompProfile` y `securityContext.appArmorProfile` existen a nivel de **pod** y a nivel de **contenedor**; gana el contenedor.
* seccomp `localhostProfile` = **ruta** bajo `/var/lib/kubelet/seccomp`. AppArmor `localhostProfile` = **nombre de perfil**. No los intercambies.
* Cargar un perfil: `sudo apparmor_parser -q -r /etc/apparmor.d/<file>` en el nodo donde va a aterrizar el pod. Verificar: `sudo aa-status`.
* Verificar desde adentro: `cat /proc/1/attr/current` y `grep Seccomp /proc/1/status`.
* Si un ejercicio dice "anotación de AppArmor", reconocé `container.apparmor.security.beta.kubernetes.io/<container>` como la forma deprecada y preferí el campo.
* seccomp `RuntimeDefault` **no** existe salvo que lo configures — el default es `Unconfined`.
* Quitar capabilities es un prerrequisito, no una alternativa: `CAP_SYS_ADMIN` reactiva syscalls que el perfil por defecto de otro modo bloquea.
* Los eventos de `kubectl describe pod` te dicen cuál de los dos mecanismos falló; `crictl inspect` te dice qué se aplicó realmente.

---

## 8. Referencias

* CKS Curriculum v1.34 — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
* Kubernetes — Restrict a Container's Syscalls with seccomp — https://kubernetes.io/docs/tutorials/security/seccomp/
* Kubernetes — Restrict a Container's Access to Resources with AppArmor — https://kubernetes.io/docs/tutorials/security/apparmor/
* Kubernetes — Security Context / `SecurityContext` API reference — https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/#security-context
* Kubernetes — Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
* Kubernetes — Pod Security Admission — https://kubernetes.io/docs/concepts/security/pod-security-admission/
* Kubernetes — Validating Admission Policy — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
* Kubernetes — Kubelet configuration (`seccompDefault`) — https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
* KEP-24 — AppArmor Support — https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/24-apparmor
* KEP-2413 — Seccomp by Default — https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/2413-seccomp-by-default
* Linux kernel — Seccomp BPF (SECure COMPuting with filters) — https://www.kernel.org/doc/html/latest/userspace-api/seccomp_filter.html
* `seccomp(2)` man page — https://man7.org/linux/man-pages/man2/seccomp.2.html
* `seccomp_unotify(2)` man page — https://man7.org/linux/man-pages/man2/seccomp_unotify.2.html
* `prctl(2)` — `PR_SET_NO_NEW_PRIVS` — https://man7.org/linux/man-pages/man2/prctl.2.html
* `capabilities(7)` man page — https://man7.org/linux/man-pages/man7/capabilities.7.html
* OCI Runtime Specification — Linux seccomp and AppArmor — https://github.com/opencontainers/runtime-spec/blob/main/config-linux.md#seccomp
* containerd — default seccomp profile source — https://github.com/containerd/containerd/blob/main/contrib/seccomp/seccomp_default.go
* Moby — `profiles/seccomp/default.json` — https://github.com/moby/moby/blob/master/profiles/seccomp/default.json
* AppArmor project wiki — https://gitlab.com/apparmor/apparmor/-/wikis/home
* `apparmor.d(5)` — profile language reference — https://manpages.ubuntu.com/manpages/noble/en/man5/apparmor.d.5.html
* `apparmor_parser(8)` — https://manpages.ubuntu.com/manpages/noble/en/man8/apparmor_parser.8.html
* `aa-status(8)`, `aa-logprof(8)`, `aa-complain(8)` — https://manpages.ubuntu.com/manpages/noble/en/man8/aa-status.8.html
* Linux LSM framework — https://www.kernel.org/doc/html/latest/admin-guide/LSM/index.html
* Security Profiles Operator — https://github.com/kubernetes-sigs/security-profiles-operator
* Security Profiles Operator — installation and usage — https://kubernetes-sigs.github.io/security-profiles-operator/
* CRI-O — seccomp and AppArmor support — https://github.com/cri-o/cri-o/blob/main/tutorials/decoupling.md
* Ubuntu — restricted unprivileged user namespaces — https://ubuntu.com/blog/ubuntu-23-10-restricted-unprivileged-user-namespaces
* NIST SP 800-190 — Application Container Security Guide — https://csrc.nist.gov/publications/detail/sp/800-190/final