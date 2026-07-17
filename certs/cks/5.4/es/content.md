## 5.4 Uso apropiado de herramientas de kernel hardening: AppArmor, seccomp

### Por qué importa

RBAC y Pod Security Standards controlan *qué* recursos de la API puede tocar un Pod, pero no limitan lo que un proceso puede hacer **dentro** del contenedor una vez que corre: qué archivos abre, qué syscalls ejecuta, si puede montar filesystems, cargar módulos, etc. AppArmor y seccomp son mecanismos del kernel de Linux (Linux Security Modules y filtrado de syscalls respectivamente) que reducen la superficie de ataque disponible para un proceso comprometido dentro del contenedor, incluso si ese proceso corre como root. Son parte de la defensa en profundidad de "runtime security preventiva", complementaria a Pod Security Admission y a las capabilities de Linux.

---

### AppArmor

**Qué es:** un LSM (Linux Security Module) que aplica perfiles de acceso a nivel de *path* y *permiso* (lectura, escritura, ejecución, mount, network, etc.) a un binario o proceso. Un perfil puede correr en modo **enforce** (bloquea y audita) o **complain**/audit (solo audita, no bloquea) — este último es útil para generar y ajustar perfiles antes de aplicarlos en producción.

#### Prerrequisitos en el nodo

AppArmor debe estar habilitado en el kernel del nodo (no todas las distros lo traen; RHEL/CentOS suelen usar SELinux en su lugar, cubierto en otro tema del curriculum):

```bash
$ cat /sys/module/apparmor/parameters/enabled
Y
```

El container runtime (containerd/CRI-O) debe soportarlo, lo cual reportan como `apparmor` en:

```bash
$ kubectl get nodes node01 -o jsonpath='{.status.nodeInfo}' | jq
```

Es responsabilidad del operador que el perfil exista **cargado en el nodo antes** de referenciarlo desde un Pod — Kubernetes no distribuye perfiles de AppArmor automáticamente (se hace vía configuración de nodo, DaemonSet con hostPath, o imagen del nodo).

#### Crear y cargar un perfil

```
# /etc/apparmor.d/k8s-deny-write
#include <tunables/global>

profile k8s-deny-write flags=(attach_disconnected) {
  #include <abstractions/base>

  file,
  network,

  deny /tmp/** w,
}
```

```bash
$ sudo apparmor_parser -q /etc/apparmor.d/k8s-deny-write
$ sudo aa-status | grep -A1 deny-write
   k8s-deny-write
```

#### Asignar el perfil a un Pod

Desde **Kubernetes v1.30**, el campo `appArmorProfile` en `securityContext` es GA y es el método recomendado (reemplaza a las anotaciones beta). Se puede definir a nivel Pod (aplica a todos los contenedores) o por contenedor:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: apparmor-demo
spec:
  containers:
  - name: nginx
    image: nginx
    securityContext:
      appArmorProfile:
        type: Localhost
        localhostProfile: k8s-deny-write
```

Valores válidos de `type`:
- `RuntimeDefault`: usa el perfil por defecto del container runtime.
- `Unconfined`: sin restricción (evitar salvo justificación explícita).
- `Localhost`: usa un perfil custom, cargado en el nodo, referenciado por `localhostProfile` (nombre del perfil, no el path del archivo).

En clusters con versión anterior a 1.30 (o para compatibilidad), el mismo efecto se logra con la anotación beta, que sigue siendo honrada:

```yaml
metadata:
  annotations:
    container.apparmor.security.beta.kubernetes.io/nginx: localhost/k8s-deny-write
```

#### Verificar

```bash
$ kubectl exec apparmor-demo -- sh -c "echo hola > /tmp/f.txt"
sh: can't create /tmp/f.txt: Permission denied

$ kubectl exec apparmor-demo -- cat /proc/1/attr/current
k8s-deny-write (enforce)
```

Si un Pod referencia un perfil `Localhost` que no está cargado en el nodo donde el scheduler lo ubica, el kubelet lo rechaza con un evento `CreateContainerConfigError` — por eso conviene distribuir los perfiles vía DaemonSet o bake-in de imagen antes de desplegar workloads que dependan de ellos.

---

### seccomp (Secure Computing Mode)

**Qué es:** un filtro de syscalls implementado en el kernel (vía BPF) que restringe qué llamadas al sistema puede invocar un proceso. A diferencia de AppArmor (rutas y permisos), seccomp opera a nivel de *interfaz kernel-userspace*: bloquea o permite syscalls específicas (`mount`, `ptrace`, `reboot`, `kexec_load`, etc.), reduciendo drásticamente la superficie atacable del kernel.

#### Tipos de perfil (`securityContext.seccompProfile.type`)

- `RuntimeDefault`: aplica el perfil por defecto del container runtime (containerd/CRI-O), que ya bloquea decenas de syscalls peligrosas (`mount`, `reboot`, `swapon`, `kexec_load`, `add_key`, etc.). **Es el perfil recomendado como baseline** para casi todos los workloads.
- `Unconfined`: sin filtro — comportamiento histórico por defecto de Docker/Kubernetes si no se especifica nada (evitar).
- `Localhost`: perfil JSON custom, cargado en el nodo bajo el directorio de seccomp del kubelet (por defecto `/var/lib/kubelet/seccomp/profiles/`).

#### Habilitar `RuntimeDefault` como default de cluster

En vez de depender de que cada manifiesto declare `seccompProfile`, se puede forzar a nivel de kubelet vía `KubeletConfiguration`:

```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
seccompDefault: true
```

Con esto, cualquier Pod que no especifique `seccompProfile` explícitamente recibe `RuntimeDefault` en lugar de `Unconfined`.

#### Crear un perfil custom

```json
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "architectures": ["SCMP_ARCH_X86_64"],
  "syscalls": [
    {
      "names": [
        "accept4", "epoll_wait", "pselect6", "futex", "nanosleep",
        "read", "write", "close", "exit", "exit_group", "clone",
        "socket", "connect", "bind", "listen", "setsockopt"
      ],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
```

`defaultAction: SCMP_ACT_ERRNO` implementa **default-deny**: toda syscall no listada devuelve error en vez de matar el proceso (alternativa más estricta: `SCMP_ACT_KILL`).

Se copia al directorio de seccomp del nodo:

```bash
$ sudo mkdir -p /var/lib/kubelet/seccomp/profiles
$ sudo cp audit.json /var/lib/kubelet/seccomp/profiles/audit.json
```

Y se referencia desde el Pod (el path es relativo al directorio `.../seccomp/`):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: seccomp-demo
spec:
  securityContext:
    seccompProfile:
      type: Localhost
      localhostProfile: profiles/audit.json
  containers:
  - name: test
    image: busybox
    command: ["sh", "-c", "chmod 777 /tmp && sleep 3600"]
```

#### Verificar comportamiento

```bash
$ kubectl logs seccomp-demo
sh: chmod: Operation not permitted
```

`Operation not permitted` (en vez de `Permission denied`) es la firma típica de un bloqueo por seccomp — distinta a la de AppArmor/RBAC, útil para diagnosticar en el examen qué mecanismo está interviniendo.

#### Generar perfiles mínimos por tracing

Escribir un allowlist a mano es propenso a error. En la práctica se generan perfiles observando las syscalls que un workload usa en condiciones normales (ej. con `strace -c -f` sobre el proceso, o herramientas como **Inspektor Gadget** — gadget `trace exec`/`profile` — o `oci-seccomp-bpf-hook**), corriendo el workload en modo `RuntimeDefault` o sin restricción, capturando el set de syscalls invocadas, y convirtiéndolo en un perfil `SCMP_ACT_ERRNO` + allowlist. Luego se valida en un entorno de staging antes de promoverlo a `enforce` en producción.

---

### AppArmor vs. seccomp vs. capabilities — cuándo usar cada uno

| Mecanismo | Granularidad | Bloquea |
|---|---|---|
| **seccomp** | syscall individual | acceso a funciones del kernel (`mount`, `ptrace`, `reboot`) |
| **AppArmor** | path + acción (r/w/x/network/mount) | acceso a archivos, sockets, capabilities específicas por ruta |
| **Linux capabilities** | permiso privilegiado agrupado | operaciones privilegiadas (`CAP_NET_ADMIN`, `CAP_SYS_ADMIN`) |

No son excluyentes: un Pod hardenizado típicamente combina los tres — `seccompProfile: RuntimeDefault` (o custom), `appArmorProfile: Localhost` con perfil restrictivo, y `capabilities.drop: ["ALL"]` con solo las capabilities estrictamente necesarias agregadas de vuelta.

---

### Buenas prácticas para el examen

- Nunca dejar `Unconfined` en producción salvo justificación documentada; `RuntimeDefault` es el mínimo aceptable.
- Probar perfiles nuevos en modo *complain*/audit (`SCMP_ACT_LOG` en seccomp, `flags=(complain)` en AppArmor) antes de pasar a *enforce* — evita romper workloads en producción por un perfil demasiado estricto.
- Los perfiles `Localhost` deben pre-existir en **cada nodo** donde pueda schedulearse el Pod; si falta, el kubelet falla la creación del contenedor con `CreateContainerConfigError`.
- Recordar el path por defecto de seccomp del kubelet (`/var/lib/kubelet/seccomp/profiles/`, configurable con `--root-dir`) y que `localhostProfile` es relativo a él.
- Desde 1.30, preferir `securityContext.appArmorProfile` sobre la anotación `container.apparmor.security.beta.kubernetes.io/<container>` (deprecated pero aún funcional).
- Diagnóstico rápido: `Permission denied` en operación de archivo → sospechar AppArmor/SELinux; `Operation not permitted` en syscall → sospechar seccomp.

---

### Referencias

- CKS Curriculum v1.34 — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubernetes docs — Restrict a Container's Access to Resources with AppArmor: https://kubernetes.io/docs/tutorials/security/apparmor/
- Kubernetes docs — Restrict a Container's Syscalls with seccomp: https://kubernetes.io/docs/tutorials/security/seccomp/
- Kubernetes API reference — PodSecurityContext / SeccompProfile / AppArmorProfile: https://kubernetes.io/docs/reference/generated/kubernetes-api/v1.34/#securitycontext-v1-core
- Kubernetes docs — Kubelet Configuration (`seccompDefault`): https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
- AppArmor project documentation: https://apparmor.net/
- Documentación del formato de perfiles seccomp (libseccomp / runc): https://github.com/opencontainers/runtime-spec/blob/main/config-linux.md#seccomp